import Foundation

/// Escopo autorizado para a análise.
///
/// A análise **nunca** varre o disco inteiro por conta própria. Ela opera
/// apenas dentro das pastas que o usuário autorizou, e o padrão é o conjunto
/// mínimo necessário. Isso não é só performance: é a garantia de que o
/// `PathGuard` usado na limpeza e a análise que a originou concordam sobre o
/// que é "dentro do escopo".
public struct AnalysisScope: Sendable {

    public let roots: [URL]
    /// Inclui `~/Downloads` como sugestão. Desligado por padrão: o PRD §7 diz
    /// que downloads antigos entram "somente como sugestão".
    public let includeDownloads: Bool
    public let limits: ScanLimits

    public init(roots: [URL], includeDownloads: Bool = false, limits: ScanLimits = .thorough) {
        self.roots = roots
        self.includeDownloads = includeDownloads
        self.limits = limits
    }

    /// Escopo padrão, conservador.
    ///
    /// A escolha é deliberada: apenas pastas cujo conteúdo é, por definição,
    /// regenerável ou descartável. `Application Support` **não** entra — pode
    /// conter documentos do usuário, e varredura massiva ali seria o oposto
    /// de transparência.
    public static func standard(includeDownloads: Bool = false) -> AnalysisScope? {
        guard let home = FileManager.default.homeDirectoryForCurrentUser else { return nil }

        var roots = [
            home.appendingPathComponent("Library/Caches", isDirectory: true),
            home.appendingPathComponent("Library/Logs", isDirectory: true),
            home.appendingPathComponent(".cache", isDirectory: true),
            home.appendingPathComponent(".Trash", isDirectory: true)
        ]
        if includeDownloads {
            roots.append(home.appendingPathComponent("Downloads", isDirectory: true))
        }

        let existing = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }

        return AnalysisScope(roots: existing, includeDownloads: includeDownloads)
    }

    /// Constrói o `PathGuard` correspondente. Uma raiz que sumiu da lista
    /// simplesmente deixa de ser autorizada.
    public func makePathGuard(ownBundle: URL? = nil) -> PathGuard {
        PathGuard(allowedRoots: roots, ownBundle: ownBundle)
    }
}

/// Resultado consolidado de uma análise.
public struct SmartScanResult: Sendable {
    public let groups: [CleanupCategoryGroup]
    public let startedAt: Date
    public let finishedAt: Date
    public let progress: ScanProgress
    /// Caminhos que não puderam ser lidos.
    public let inaccessiblePaths: [String]
    /// O escopo realmente varrido, para exibir na interface.
    public let scannedRoots: [URL]

    /// Total recuperável: soma apenas de tamanhos medidos, sem duplicidade.
    ///
    /// A deduplicação por caminho acontece antes da soma. Sem isso, um cache
    /// dentro de `~/Library/Application Support` que também apareça na lista de
    /// "outros candidatos" contaria duas vezes — e o número inflado faria a
    /// limpeza parecer melhor do que é.
    public var totalRecoverable: Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        for group in groups {
            for candidate in group.candidates {
                guard let size = candidate.sizeOnDisk, size > 0 else { continue }
                if seen.insert(candidate.url.standardizedFileURL.path).inserted {
                    total += size
                }
            }
        }
        return total
    }

    public var totalCandidates: Int {
        groups.reduce(0) { $0 + $1.candidates.count }
    }
}

/// ## Coordenador da análise consolidada
///
/// O PRD §7 chama isso de "análise central que reúna resultados dos demais
/// módulos". O valor para o usuário é receber **um** relatório em vez de nove
/// telas para consultar. O valor técnico é que a deduplicação e a contabilidade
/// de espaço acontecem em um único lugar — o que torna impossível dois módulos
/// reportarem o mesmo arquivo duas vezes.
public struct SmartScanCoordinator: Sendable {

    private let fs: FileSystem
    private let scanner: DirectoryScanner

    public init(fs: FileSystem = .live) {
        self.fs = fs
        self.scanner = DirectoryScanner(fs: fs)
    }

    /// Executa a análise consolidada.
    ///
    /// - Throws: `CancellationError` se o usuário cancelar.
    public func run(
        scope: AnalysisScope,
        progress: @Sendable @escaping (ScanProgress) -> Void = { _ in }
    ) async throws -> SmartScanResult {
        let startedAt = Date()
        var candidates: [CleanupCandidate] = []
        var inaccessible: [String] = []
        var lastProgress = ScanProgress()

        // 1. Caches e logs de aplicativos.
        let (cacheResult, cacheInaccessible) = await analyzeCachesAndLogs(scope: scope) { update in
            lastProgress = update
            progress(update)
        }
        candidates.append(contentsOf: cacheResult)
        inaccessible.append(contentsOf: cacheInaccessible)

        // 2. Lixeira — categoria separada, porque exige confirmação própria.
        candidates.append(contentsOf: analyzeTrash(scope: scope))

        // 3. Downloads antigos, apenas como sugestão.
        if scope.includeDownloads {
            candidates.append(contentsOf: await analyzeOldDownloads(scope: scope))
        }

        // 4. Dados de desenvolvimento reconhecidos, nunca pré-selecionados.
        candidates.append(contentsOf: await analyzeDeveloperData(scope: scope))

        // 5. Deduplicação: o mesmo caminho não pode aparecer em duas categorias.
        let deduped = Self.deduplicating(candidates)

        let groups = Self.grouping(deduped)
        let total = deduped.compactMap(\.sizeOnDisk).reduce(0, +)

        let final = ScanProgress(
            filesVisited: lastProgress.filesVisited,
            matchesFound: deduped.count,
            bytesMatched: total,
            currentPath: nil,
            fraction: 1,
            isFinished: true
        )
        progress(final)

        return SmartScanResult(
            groups: groups,
            startedAt: startedAt,
            finishedAt: Date(),
            progress: final,
            inaccessiblePaths: inaccessible,
            scannedRoots: scope.roots
        )
    }

    // MARK: - Categorias

    /// Caches e logs dentro das pastas autorizadas.
    ///
    /// O critério é **localização**, não nome: estar em `~/Library/Caches` já é
    /// a evidência. Um cache fora dessa árvore não é identificado, mesmo que
    /// o nome sugira ser.
    private func analyzeCachesAndLogs(
        scope: AnalysisScope,
        progress: @Sendable @escaping (ScanProgress) -> Void
    ) async -> ([CleanupCandidate], [String]) {
        let scanner = self.scanner

        let result = try? await scanner.scanLargeFiles(
            roots: scope.roots,
            // Zero: aqui varremos diretórios, não arquivos grandes.
            query: FileQuery(minimumSize: 0),
            limits: scope.limits,
            progress: progress
        )

        guard let result else { return ([], []) }

        let isLogs = { (url: URL) in
            url.path.contains("/Library/Logs/") || url.pathExtension.lowercased() == "log"
        }

        let candidates = result.files.map { entry in
            let log = isLogs(entry.url)
            return CleanupCandidate(
                url: entry.url,
                category: log ? .oldLogs : .applicationCache,
                reason: log
                    ? "Arquivo de log em pasta de logs. Regenerado pelo aplicativo."
                    : "Cache em pasta de cache. O aplicativo recria quando necessário.",
                confidence: .certain,
                sizeOnDisk: entry.sizeOnDisk,
                isDirectory: entry.isDirectory,
                consequence: "O conteúdo será regenerado pelo aplicativo na próxima execução.",
                isInSyncedFolder: entry.isInSyncedFolder
            )
        }

        return (candidates, result.inaccessiblePaths)
    }

    /// Conteúdo da Lixeira, como categoria isolada.
    private func analyzeTrash(scope: AnalysisScope) -> [CleanupCandidate] {
        guard let trash = scope.roots.first(where: { $0.lastPathComponent == ".Trash" }),
              let entries = try? fs.contents(of: trash),
              !entries.isEmpty else {
            return []
        }

        let total = entries.compactMap { fs.allocatedSize(of: $0) }.reduce(0, +)

        // Um item agrupado, em vez de um item por arquivo. Esvaziar a Lixeira
        // é uma decisão única, e apresentar hundreds de linhas daria a impressão
        // de uma granularidade que a operação não tem.
        return [
            CleanupCandidate(
                url: trash,
                category: .trash,
                reason: "Lixeira: \(entries.count) itens esperando remoção definitiva.",
                confidence: .certain,
                sizeOnDisk: total,
                isDirectory: true,
                consequence: "A remoção da Lixeira é definitiva e não pode ser desfeita. Confira se não há nada que queira recuperar.",
                isInSyncedFolder: false
            )
        ]
    }

    /// Downloads antigos — **sempre** como sugestão, nunca pré-selecionado.
    private func analyzeOldDownloads(scope: AnalysisScope) async -> [CleanupCandidate] {
        guard let downloads = scope.roots.first(where: { $0.lastPathComponent == "Downloads" }) else {
            return []
        }

        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
        let syncedRoots = SyncedFolderDetector.detect()

        let result = try? await scanner.scanLargeFiles(
            roots: [downloads],
            query: FileQuery(modifiedAfter: cutoff),
            limits: .quick
        )

        guard let result else { return [] }

        return result.files.map { entry in
            CleanupCandidate(
                url: entry.url,
                category: .oldDownloads,
                reason: "Em Downloads e sem modificação há mais de 6 meses.",
                // `.uncertain` garante que nunca venha marcado: o PRD §7 diz
                // "somente como sugestão".
                confidence: .uncertain,
                sizeOnDisk: entry.sizeOnDisk,
                isDirectory: entry.isDirectory,
                consequence: "Pode ser o único exemplar de um arquivo seu. Confira antes.",
                isInSyncedFolder: syncedRoots.contains { entry.url.path.hasPrefix($0) }
            )
        }
    }

    /// Dados de desenvolvimento reconhecidos por caminho.
    ///
    /// Todos com confiança `.likely` e **nunca** pré-selecionados: remover
    /// `DerivedData` ou cache de gerenciador de pacotes leva a recompilações
    /// demoradas, e o usuário precisa saber disso antes de aceitar.
    private func analyzeDeveloperData(scope: AnalysisScope) async -> [CleanupCandidate] {
        guard let home = FileManager.default.homeDirectoryForCurrentUser else { return [] }

        let known: [(URL, String, String)] = [
            (home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
             "Cache de compilação do Xcode.",
             "O Xcode recompila o projeto do zero. Pode levar vários minutos."),
            (home.appendingPathComponent("Library/Developer/Xcode/Archives"),
             "Arquivos de build arquivados.",
             "Inclui versões submitted previously. Confirme se ainda precisa."),
            (home.appendingPathComponent(".npm"),
             "Cache do gerenciador de pacotes npm.",
             "Os pacotes serão baixados novamente na próxima instalação."),
            (home.appendingPathComponent(".gradle/caches"),
             "Cache do Gradle.",
             "Gradle vai rebaixar as dependências na próxima compilação."),
            (home.appendingPathComponent("Library/Caches/CocoaPods"),
             "Cache do CocoaPods.",
             "Os pods serão rebaixados pelo Podfile.")
        ]

        return known.compactMap { url, reason, consequence in
            guard fs.itemExists(at: url) else { return nil }
            return CleanupCandidate(
                url: url,
                category: .developerData,
                reason: reason,
                confidence: .likely,
                sizeOnDisk: fs.allocatedSize(of: url),
                isDirectory: true,
                consequence: consequence,
                isInSyncedFolder: false
            )
        }
    }

    // MARK: - Consolidação

    /// Remove candidatos cujo caminho já apareceu.
    ///
    /// A primeira ocorrência vence, e as categorias são ordenadas por
    /// confiança para que o motivo mais forte prevaleça sobre um mais fraco.
    private static func deduplicating(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        var best: [String: CleanupCandidate] = [:]
        var order: [String] = []

        for candidate in candidates {
            let key = candidate.url.standardizedFileURL.path
            if let existing = best[key] {
                if candidate.confidence > existing.confidence {
                    best[key] = candidate
                }
            } else {
                best[key] = candidate
                order.append(key)
            }
        }

        return order.compactMap { best[$0] }
    }

    private static func grouping(_ candidates: [CleanupCandidate]) -> [CleanupCategoryGroup] {
        let order: [CleanupCategory] = [
            .trash,
            .applicationCache,
            .oldLogs,
            .temporaryFiles,
            .applicationLeftovers,
            .browserData,
            .developerData,
            .oldDownloads,
            .duplicates,
            .largeFiles,
            .other
        ]

        return order.compactMap { category in
            let items = candidates.filter { $0.category == category }
            guard !items.isEmpty else { return nil }
            return CleanupCategoryGroup(category: category, candidates: items)
        }
    }
}
