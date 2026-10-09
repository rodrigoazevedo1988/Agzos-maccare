import Foundation
import MacCareCore
import Observation

/// ## Estado da tela de arquivos grandes
///
/// O princípio que organiza este view model: **arquivo grande não é lixo**.
///
/// Não existe seleção automática, nem categoria que o app considere "lixo por
/// ser grande". Existe uma lista para o usuário revisar e um caminho explícito
/// de remoção, que sempre termina em `performCleanup` com confirmação. O
/// resultado é que o app informa e o usuário decide — a ordem importa, porque
/// a decisão invertida é o que transforma um app de manutenção em uma limpeza
/// de dados do usuário.
@Observable
@MainActor
final class LargeFilesModel {

    // MARK: - Ordenação

    enum Sort: String, CaseIterable, Identifiable {
        case sizeDescending
        case sizeAscending
        case newest
        case oldest
        case name

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sizeDescending: return "Maiores primeiro"
            case .sizeAscending: return "Menores primeiro"
            case .newest: return "Modificados recentemente"
            case .oldest: return "Modificados há mais tempo"
            case .name: return "Nome"
            }
        }
    }

    /// Limites de tamanho pré-definidos. Um controle deslizante de bytes seria
    /// mais fino e menos usável: nobody escolhe "137,4 MB" como critério de
    /// revisão, e um valor livre transformaria a comparação em adivinhação.
    enum SizeThreshold: Int64, CaseIterable, Identifiable {
        case none = 0
        case megabytes50 = 52_428_800
        case megabytes100 = 104_857_600
        case megabytes250 = 262_144_000
        case megabytes500 = 524_288_000
        case gigabyte1 = 1_073_741_824
        case gigabyte2 = 2_147_483_648
        case gigabyte5 = 5_368_709_120

        var id: Int64 { rawValue }

        var title: String {
            switch self {
            case .none: return "Qualquer tamanho"
            case .megabytes50: return "A partir de 50 MB"
            case .megabytes100: return "A partir de 100 MB"
            case .megabytes250: return "A partir de 250 MB"
            case .megabytes500: return "A partir de 500 MB"
            case .gigabyte1: return "A partir de 1 GB"
            case .gigabyte2: return "A partir de 2 GB"
            case .gigabyte5: return "A partir de 5 GB"
            }
        }

        /// `nil` = sem filtro, que é o que o `FileQuery` espera.
        var bytes: Int64? { self == .none ? nil : rawValue }
    }

    // MARK: - Filtros

    var minimumSize: SizeThreshold = .megabytes100
    var extensionText: String = ""
    var filtersByDate = false
    var modifiedAfter: Date = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
    var includeDirectories = false
    var sort: Sort = .sizeDescending

    /// Pastas escolhidas pelo usuário. Vazio até ele escolher: o app não
    /// varre `~/Downloads` por conta própria.
    var roots: [URL] = []
    var isChoosingFolder = false

    // MARK: - Estado da execução

    private(set) var isScanning = false
    private(set) var isRemoving = false
    private(set) var progress = ScanProgress()
    private(set) var result: LargeFileScanResult?
    private(set) var report: RemovalReport?
    private(set) var wasCancelled = false
    var errorMessage: String?

    /// `FileQuery` efetivamente aplicada na última varredura, para avisar que
    /// os filtros mudaram e o resultado na tela não os reflete.
    @ObservationIgnored private var appliedQuery: FileQuery?

    /// Itens marcados para a lista de revisão.
    var reviewIDs: Set<String> = []

    /// Itens já removidos nesta sessão, para que saiam da lista sem exigir uma
    /// nova varredura.
    private(set) var processedIDs: Set<String> = []

    /// Itens aguardando confirmação de remoção.
    private(set) var pendingRemoval: [LargeFileEntry] = []
    var showRemovalConfirmation = false

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var removalTask: Task<Void, Never>?

    init() {}

    // MARK: - Pastas

    func addRoot(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard !roots.contains(where: { $0.standardizedFileURL == normalized }) else { return }
        roots.append(normalized)
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
    }

    /// Pastas oferecidas como atalho. São apenas *sugestões*: aparecem como
    /// botões e só entram no escopo quando o usuário clica.
    var suggestedRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true)
        ]
        .filter { FileManager.default.fileExists(atPath: $0.path) }
        .filter { suggestion in
            !roots.contains { $0.standardizedFileURL == suggestion.standardizedFileURL }
        }
    }

    var canScan: Bool { !roots.isEmpty && !isScanning && !isRemoving }

    // MARK: - Consulta

    /// Extensões digitadas, normalizadas para minúsculas e sem ponto.
    /// Texto vazio significa "todas" — representado por `nil`, e não por
    /// conjunto vazio, que filtraria tudo fora.
    var parsedExtensions: Set<String>? {
        let parts = extensionText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : Set(parts)
    }

    var currentQuery: FileQuery {
        FileQuery(
            minimumSize: minimumSize.bytes,
            allowedExtensions: parsedExtensions,
            modifiedAfter: filtersByDate ? modifiedAfter : nil,
            includeDirectories: includeDirectories
        )
    }

    /// `true` quando o usuário mexeu nos filtros depois da última varredura.
    /// Sem este aviso, o resultado antigo continuaria na tela parecendo
    /// respeitar os filtros novos — que é a forma mais sutil de mentir.
    var filtersChanged: Bool {
        guard let appliedQuery else { return !roots.isEmpty }
        return appliedQuery != currentQuery
    }

    // MARK: - Varredura

    func startScan(environment: AppEnvironment) {
        guard canScan else { return }

        scanTask?.cancel()
        isScanning = true
        wasCancelled = false
        errorMessage = nil
        report = nil
        result = nil
        reviewIDs = []
        processedIDs = []
        progress = ScanProgress()

        let scanner = environment.scanner
        let query = currentQuery
        let limits = environment.scope?.limits ?? .thorough
        let roots = roots

        scanTask = Task { [weak self] in
            await self?.runScan(scanner: scanner, roots: roots, query: query, limits: limits)
        }
    }

    private func runScan(
        scanner: DirectoryScanner,
        roots: [URL],
        query: FileQuery,
        limits: ScanLimits
    ) async {
        let handler: @Sendable (ScanProgress) -> Void = { [weak self] update in
            Task { @MainActor in self?.progress = update }
        }

        do {
            let outcome = try await scanner.scanLargeFiles(
                roots: roots,
                query: query,
                limits: limits,
                progress: handler
            )
            result = outcome
            progress = outcome.progress
            appliedQuery = query
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            errorMessage = Self.message(for: error)
        }

        isScanning = false
        scanTask = nil
    }

    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        wasCancelled = true
    }

    // MARK: - Resultados

    var visibleEntries: [LargeFileEntry] {
        let files = result?.files ?? []
        let remaining = files.filter { !processedIDs.contains($0.id) }
        switch sort {
        case .sizeDescending:
            return remaining.sorted { $0.sizeOnDisk > $1.sizeOnDisk }
        case .sizeAscending:
            return remaining.sorted { $0.sizeOnDisk < $1.sizeOnDisk }
        case .newest:
            return remaining.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        case .oldest:
            return remaining.sorted { ($0.modificationDate ?? .distantFuture) < ($1.modificationDate ?? .distantFuture) }
        case .name:
            return remaining.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
    }

    /// Soma de itens que ainda constam na lista. Itens já removidos saem da
    /// soma porque já não ocupam espaço.
    var totalSize: Int64 {
        visibleEntries.reduce(0) { $0 + $1.sizeOnDisk }
    }

    // MARK: - Lista de revisão

    func isInReview(_ entry: LargeFileEntry) -> Bool {
        reviewIDs.contains(entry.id)
    }

    func toggleReview(_ entry: LargeFileEntry) {
        if reviewIDs.contains(entry.id) {
            reviewIDs.remove(entry.id)
        } else {
            reviewIDs.insert(entry.id)
        }
    }

    func clearReview() {
        reviewIDs = []
    }

    func dismissReport() {
        report = nil
    }

    var reviewEntries: [LargeFileEntry] {
        visibleEntries.filter { reviewIDs.contains($0.id) }
    }

    var reviewTotalSize: Int64 {
        reviewEntries.reduce(0) { $0 + $1.sizeOnDisk }
    }

    // MARK: - Remoção

    /// Prepara a remoção e **não** executa. Quem confirma é o diálogo.
    func beginRemoval(entries: [LargeFileEntry]) {
        guard !entries.isEmpty, !isRemoving else { return }
        pendingRemoval = entries
        report = nil
        showRemovalConfirmation = true
    }

    func cancelRemovalRequest() {
        pendingRemoval = []
        showRemovalConfirmation = false
    }

    func confirmRemoval(environment: AppEnvironment) {
        let entries = pendingRemoval
        guard !entries.isEmpty, !isRemoving else { return }

        pendingRemoval = []
        showRemovalConfirmation = false
        isRemoving = true
        errorMessage = nil

        removalTask = Task { [weak self] in
            await self?.runRemoval(entries: entries, environment: environment)
        }
    }

    private func runRemoval(entries: [LargeFileEntry], environment: AppEnvironment) async {
        let candidates = entries.map(Self.candidate(for:))

        do {
            let outcome = try await environment.performCleanup(
                candidates: candidates,
                strategy: .moveToTrash,
                kind: .largeFileReview
            )
            report = outcome.report

            // Só o que de fato saiu do disco sai da lista. Um item que
            // falhou continua lá, porque continua existindo.
            let removed = Set(outcome.report.outcomes
                .filter { $0.disposition == .movedToTrash || $0.disposition == .permanentlyDeleted }
                .map(\.url.path))
            processedIDs.formUnion(removed)
            reviewIDs.subtract(entries.map(\.id).filter { removed.contains($0) })
        } catch is CancellationError {
            errorMessage = "A remoção foi interrompida. Alguns itens podem já ter sido movidos para a Lixeira — execute a varredura novamente para conferir."
        } catch {
            errorMessage = Self.message(for: error)
        }

        isRemoving = false
        removalTask = nil
    }

    /// Converte um item da lista em candidato de limpeza.
    ///
    /// O motivo é literal e a consequência é dita antes da seleção, porque
    /// "arquivo grande" não é um indício de que o arquivo seja descartável.
    static func candidate(for entry: LargeFileEntry) -> CleanupCandidate {
        CleanupCandidate(
            url: entry.url,
            category: .largeFiles,
            reason: entry.isDirectory
                ? "Pasta de \(ByteSizeFormatter.format(entry.sizeOnDisk)) marcada na revisão de arquivos grandes."
                : "Arquivo de \(ByteSizeFormatter.format(entry.sizeOnDisk)) marcado na revisão de arquivos grandes.",
            confidence: .certain,
            sizeOnDisk: entry.sizeOnDisk,
            isDirectory: entry.isDirectory,
            consequence: "Tamanho não é motivo de descarte. Se este for o único exemplar do conteúdo, movê-lo para a Lixeira é o primeiro passo de uma remoção que se torna definitiva quando a Lixeira for esvaziada.",
            isInSyncedFolder: entry.isInSyncedFolder
        )
    }

    // MARK: - Apoio

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
