import Foundation

/// Descoberta de aplicativos instalados.
///
/// ## Escopo real
///
/// O app descobre aplicativos em `/Applications`, `~/Applications` e pastas
/// que o usuário adicionar. Não usa `Launch Services` para *encontrar* apps
/// porque a enumeração do sistema é opaca e não permite justificar a origem de
/// cada item — e o PRD §13 exige mostrar caminho e origem. A leitura direta do
/// filesystem é mais lenta e muito mais transparente.
public struct ApplicationCatalog: Sendable {

    private let fs: FileSystem
    private let additionalRoots: [URL]

    public init(fs: FileSystem = LiveFileSystem(), additionalRoots: [URL] = []) {
        self.fs = fs
        self.additionalRoots = additionalRoots
    }

    /// Diretórios varridos por padrão.
    public static var defaultRoots: [(url: URL, location: ApplicationLocation)] {
        var roots: [(URL, ApplicationLocation)] = [
            (URL(fileURLWithPath: "/Applications", isDirectory: true), .systemApplications)
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append((home.appendingPathComponent("Applications", isDirectory: true), .userApplications))
        return roots.map { (url: $0.0, location: $0.1) }
    }

    /// Lista todos os aplicativos encontrados, com metadados do `Info.plist`.
    public func listApplications(includeSizes: Bool = true) -> [ApplicationEntry] {
        let syncedRoots = SyncedFolderDetector.detect()
        var found: [ApplicationEntry] = []
        var seenPaths = Set<String>()

        var roots: [(URL, ApplicationLocation)] = Self.defaultRoots
        roots.append(contentsOf: additionalRoots.map { ($0, .additional) })

        for (root, location) in roots {
            guard let children = try? fs.contents(of: root) else { continue }

            for url in children {
                let path = url.path
                guard !seenPaths.contains(path) else { continue }
                guard fs.isDirectory(at: url) else { continue }
                guard url.pathExtension.lowercased() == "app" else { continue }
                seenPaths.insert(path)

                guard let entry = makeEntry(url: url, location: location, syncedRoots: syncedRoots) else {
                    continue
                }
                var withSize = entry
                if includeSizes {
                    withSize = ApplicationEntry(
                        url: entry.url,
                        name: entry.name,
                        bundleIdentifier: entry.bundleIdentifier,
                        shortVersion: entry.shortVersion,
                        buildVersion: entry.buildVersion,
                        category: entry.category,
                        minimumSystemVersion: entry.minimumSystemVersion,
                        location: entry.location,
                        sizeOnDisk: FileSizeMeasurer.directorySize(of: url, fs: fs),
                        modificationDate: fs.modificationDate(of: url),
                        isInSyncedFolder: entry.isInSyncedFolder,
                        isAppleProvided: entry.isAppleProvided
                    )
                }
                found.append(withSize)
            }
        }

        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Monta a entrada lendo o `Info.plist` do bundle.
    private func makeEntry(url: URL, location: ApplicationLocation, syncedRoots: [String]) -> ApplicationEntry? {
        // Um `.app` sem `Info.plist` legível não é um aplicativo — pode ser uma
        // pasta qualquer. Descartá-lo aqui evita poluir a lista com diretórios
        // que o usuário não instalou.
        guard let info = Self.readInfoPlist(at: url) else { return nil }

        let bundleID = info["CFBundleIdentifier"] as? String
        let name = (info["CFBundleName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        return ApplicationEntry(
            url: url,
            name: name,
            bundleIdentifier: bundleID,
            shortVersion: info["CFBundleShortVersionString"] as? String,
            buildVersion: info["CFBundleVersion"] as? String,
            category: info["LSApplicationCategoryType"] as? String,
            minimumSystemVersion: info["LSMinimumSystemVersion"] as? String,
            location: location,
            sizeOnDisk: nil,
            modificationDate: fs.modificationDate(of: url),
            isInSyncedFolder: syncedRoots.contains { url.path.hasPrefix($0) },
            isAppleProvided: Self.isAppleProvided(info: info, path: url.path)
        )
    }

    /// Distingue aplicativos da Apple sem adivinhar pelo nome.
    private static func isAppleProvided(info: [String: Any], path: String) -> Bool {
        if let team = info["com.apple.teamid"] as? String { return team == "apple" }
        if path.hasPrefix("/System/Applications") { return true }
        // Identificadores de prefixo bem conhecido da Apple. Lista curta e
        // explícita de propósito: um prefixo amplo geraria falso positivo em
        // apps de terceiros que imitam nomenclatura.
        guard let bundleID = info["CFBundleIdentifier"] as? String else { return false }
        return bundleID.hasPrefix("com.apple.")
    }

    /// Lê o `Info.plist` de um bundle.
    ///
    /// Usa `NSDictionary(contentsOf:)` em vez de `PropertyListSerialization`
    /// porque o bundle pode conter plist em formato binário ou XML, e ambos
    /// são válidos.
    static func readInfoPlist(at appURL: URL) -> [String: Any]? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        // `PropertyListSerialization` é o caminho tipado e correto. A
        // alternativa com `NSDictionary(contentsOf:)` chega ao mesmo dicionário
        // como `Any` e obrigaria a um cast forçado.
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else { return nil }
        return dictionary
    }
}

/// ## Desinstalador
///
/// ## O que este tipo **não** faz, por decisão
///
/// - Não apaga "preferências compartilhadas" sem confirmação específica.
/// - Não remove arquivos de outros aplicativos.
/// - Não tenta contornar SIP, TCC ou Gatekeeper.
/// - Não apaga o bundle sem passar por `SafeFileRemover`.
///
/// ## O que ele não consegue fazer, e diz isso
///
/// Itens dentro de `~/Library/Group Containers` exigem que o app esteja
/// Hardened Runtime e, em vários casos, permissão explícita. Quando a remoção
/// falha por permissão, o relatório informa a limitação em vez de fingir
/// sucesso.
public struct Uninstaller: Sendable {

    private let fs: FileSystem

    public init(fs: FileSystem = LiveFileSystem()) {
        self.fs = fs
    }

    /// Localizações onde residuais de um aplicativo costumam ficar.
    ///
    /// A ordem reflete a confiança: as primeiras são fortemente associadas ao
    /// bundle, as últimas são apenas "sempre que o app passou por aqui".
    private static func residualLocations(bundleID: String, appName: String) -> [(URL, LeftoverArtifact.Association)] {
        let home = FileManager.default.homeDirectoryForCurrentUser

        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
        let container = home.appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
        let webKit = home.appendingPathComponent("Library/WebKit", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
        let httpStorages = home.appendingPathComponent("Library/HTTPStorages", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
        let savedState = home.appendingPathComponent("Library/Saved Application State", isDirectory: true)
            .appendingPathComponent("\(bundleID).savedState", isDirectory: true)
        let prefs = home.appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleID).plist")
        let systemPrefs = URL(fileURLWithPath: "/Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleID).plist")

        return [
            (support, .bundleIdentifierMatch),
            (caches, .bundleIdentifierMatch),
            (container, .bundleIdentifierMatch),
            (webKit, .bundleIdentifierMatch),
            (httpStorages, .bundleIdentifierMatch),
            (savedState, .bundleIdentifierMatch),
            (prefs, .bundleIdentifierMatch),
            (systemPrefs, .bundleIdentifierMatch),
            // Pistas de sistema: confiança menor, exigem confirmação reforçada
            (URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)
                .appendingPathComponent(bundleID, isDirectory: true), .locationMatch),
            (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(bundleID).plist"), .locationMatch),
            (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
                .appendingPathComponent("\(bundleID).plist"), .locationMatch),
            (home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(bundleID).plist"), .locationMatch),
            (home.appendingPathComponent("Library/Application Scripts", isDirectory: true)
                .appendingPathComponent(bundleID, isDirectory: true), .locationMatch)
        ]
    }

    /// Encontra residuais de um aplicativo, sem remover nada.
    ///
    /// - Returns: artefatos existentes, com nível de confiança e aviso.
    public func findLeftovers(for application: ApplicationEntry) -> [LeftoverArtifact] {
        guard let bundleID = application.bundleIdentifier else {
            // Sem identificador, qualquer correspondência seria por nome —
            // exatamente o que o PRD proíbe. Devolve vazio, não chute.
            return []
        }

        var artifacts: [LeftoverArtifact] = []

        for (url, association) in Self.residualLocations(bundleID: bundleID, appName: application.name) {
            guard fs.itemExists(at: url) else { continue }
            let isDirectory = fs.isDirectory(at: url)

            artifacts.append(
                LeftoverArtifact(
                    url: url,
                    association: association,
                    sizeOnDisk: fs.allocatedSize(of: url),
                    isDirectory: isDirectory,
                    warning: Self.warning(for: url, isDirectory: isDirectory, application: application)
                )
            )
        }

        return artifacts.sorted { lhs, rhs in
            if lhs.association.confidence != rhs.association.confidence {
                return lhs.association.confidence > rhs.association.confidence
            }
            return (lhs.sizeOnDisk ?? 0) > (rhs.sizeOnDisk ?? 0)
        }
    }

    /// Avisos exibidos antes da confirmação.
    ///
    /// A distinção que importa: cache e preferências são regeneráveis;
    /// `Application Support` costuma guardar documentos que o usuário salvou e
    /// que **nenhum** aplicativo vai regenerar.
    private static func warning(for url: URL, isDirectory: Bool, application: ApplicationEntry) -> String? {
        let path = url.path
        if path.contains("/Application Support/") {
            return "Pode conter arquivos, projetos ou documentos criados por você em \(application.name). Não são regenerados pelo aplicativo."
        }
        if path.contains("/Containers/") {
            return "Contém o container de dados do \(application.name), que pode incluir documentos e dados de login."
        }
        if path.contains("/Preferences/") {
            return "Preferências do \(application.name). Serão restauradas aos valores padrão se você desinstalar."
        }
        if path.hasPrefix("/Library/") {
            return "Localizado no nível do sistema. Pode exigir permissões adicionais para remover."
        }
        if isDirectory {
            return nil
        }
        return nil
    }

    /// Constrói os candidatos de limpeza para o desinstalador.
    ///
    /// O bundle do aplicativo entra como item separado e com confiança máxima;
    /// os residuais entram classificados pela confiança da associação.
    public func removalCandidates(for application: ApplicationEntry) -> [CleanupCandidate] {
        var candidates: [CleanupCandidate] = [
            CleanupCandidate(
                url: application.url,
                category: .applicationLeftovers,
                reason: "Bundle do aplicativo \(application.name).",
                confidence: .certain,
                sizeOnDisk: application.sizeOnDisk,
                isDirectory: true,
                consequence: "O \(application.name) será desinstalado. Ele deixa de abrir até ser reinstalado.",
                isInSyncedFolder: application.isInSyncedFolder
            )
        ]

        for artifact in findLeftovers(for: application) {
            candidates.append(
                CleanupCandidate(
                    url: artifact.url,
                    category: .applicationLeftovers,
                    reason: "Arquivos de \(application.name) — \(artifact.association.title.lowercased()).",
                    confidence: artifact.association.confidence,
                    sizeOnDisk: artifact.sizeOnDisk,
                    isDirectory: artifact.isDirectory,
                    consequence: artifact.warning,
                    isInSyncedFolder: false
                )
            )
        }

        return candidates
    }
}
