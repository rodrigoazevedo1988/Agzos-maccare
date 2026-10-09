import Foundation
import MacCareCore
import Observation

/// ## Estado da tela de duplicados
///
/// A regra que governa este arquivo é a do PRD §11, e ela tem duas partes que
/// costumam ser implementadas como uma só — quando na verdade precisam ser
/// separadas:
///
/// 1. **Preservar uma cópia.** A `keepSuggestion` do núcleo é a cópia mais
///    antiga do grupo, e ela define a seleção inicial: tudo marcado, exceto
///    ela. A sugestão é aplicada sozinha; ela é *visível*, e o usuário pode
///    discordar.
/// 2. **Nunca remover todas sem dizer.** Remover todas as cópias é legítimo —
///    às vezes o arquivo é realmente dispensável —, mas o diálogo de
///    confirmação nomeia os grupos que ficariam sem nenhum exemplar. O app
///    não impede a ação; ele garante que ela não acontece por engano.
@Observable
@MainActor
final class DuplicatesModel {

    // MARK: - Escopo

    /// Pastas escolhidas pelo usuário. Vazias até ele escolher.
    var roots: [URL] = []
    var isChoosingFolder = false

    // MARK: - Estado da execução

    private(set) var isSearching = false
    private(set) var isRemoving = false
    private(set) var progress = ScanProgress()
    private(set) var groups: [DuplicateGroup] = []
    private(set) var report: RemovalReport?
    private(set) var wasCancelled = false
    /// Distingue "ainda não busquei" de "busquei e não achei nada" — são duas
    /// situações que pedem textos diferentes, e mostrar a primeira depois de
    /// uma busca vazia seria dizer ao usuário que o app não fez o trabalho.
    private(set) var hasSearched = false
    var errorMessage: String?

    /// Cópias marcadas para remoção, por caminho (`LargeFileEntry.id`).
    var selection: Set<String> = []

    /// Grupos abertos na interface.
    var expandedGroupIDs: Set<String> = []

    /// Cópias aguardando confirmação de remoção.
    private(set) var pendingRemoval: [LargeFileEntry] = []
    var showRemovalConfirmation = false

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var duplicateWork: Task<[DuplicateGroup], Error>?
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

    var canSearch: Bool { !roots.isEmpty && !isSearching && !isRemoving }

    // MARK: - Busca

    func startSearch(environment: AppEnvironment) {
        guard canSearch else { return }

        searchTask?.cancel()
        duplicateWork?.cancel()
        isSearching = true
        wasCancelled = false
        errorMessage = nil
        report = nil
        groups = []
        hasSearched = false
        selection = []
        expandedGroupIDs = []
        progress = ScanProgress()

        let finder = environment.duplicates
        let roots = roots

        searchTask = Task { [weak self] in
            await self?.runSearch(finder: finder, roots: roots)
        }
    }

    private func runSearch(finder: DuplicateFinder, roots: [URL]) async {
        let handler: @Sendable (ScanProgress) -> Void = { [weak self] update in
            Task { @MainActor in
                // A checagem evita que um progresso emitido depois do
                // cancelamento reabra o estado de "buscando".
                guard let self, self.isSearching else { return }
                self.progress = update
            }
        }

        // `DuplicateFinder` é um tipo não isolado: a enumeração do disco
        // acontece de forma síncrona dentro dele e rodaria na executor do
        // chamador, travando a interface e o botão de cancelar. A task
        // destacada resolve isso — mas, por definição, ela não é filha desta,
        // então o cancelamento não se propaga sozinho. Por isso a handle fica
        // guardada e é cancelada explicitamente em `cancelSearch()`.
        let work = Task.detached(priority: .userInitiated) { () throws -> [DuplicateGroup] in
            try await finder.findDuplicates(in: roots, progress: handler)
        }
        duplicateWork = work

        do {
            let found = try await work.value
            groups = found
            hasSearched = true
            applyDefaultSelection()
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            errorMessage = Self.message(for: error)
        }

        duplicateWork = nil
        isSearching = false
        searchTask = nil
    }

    /// Seleção inicial derivada da sugestão do núcleo.
    ///
    /// A `keepSuggestion` fica de fora, e o grupo correspondente é aberto: o
    /// usuário precisa ver qual cópia o app decidiu preservar para poder
    /// discordar dela.
    private func applyDefaultSelection() {
        var marked: Set<String> = []
        var expanded: Set<String> = []

        for group in groups {
            let keep = group.keepSuggestion?.id
            for item in group.items where item.id != keep {
                marked.insert(item.id)
            }
            expanded.insert(group.id)
        }

        selection = marked
        expandedGroupIDs = expanded
    }

    func cancelSearch() {
        guard isSearching else { return }
        duplicateWork?.cancel()
        searchTask?.cancel()
        duplicateWork = nil
        searchTask = nil
        isSearching = false
        wasCancelled = true
    }

    func dismissReport() {
        report = nil
    }

    // MARK: - Seleção

    func isSelected(_ item: LargeFileEntry) -> Bool {
        selection.contains(item.id)
    }

    func isKeepSuggestion(_ item: LargeFileEntry, in group: DuplicateGroup) -> Bool {
        group.keepSuggestion?.id == item.id
    }

    func toggle(_ item: LargeFileEntry) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    /// "Marcar todas, menos a sugerida" — o padrão declarado na linha de base.
    func resetGroup(_ group: DuplicateGroup) {
        let keep = group.keepSuggestion?.id
        selection.subtract(group.items.map(\.id))
        for item in group.items where item.id != keep {
            selection.insert(item.id)
        }
    }

    func clearGroup(_ group: DuplicateGroup) {
        selection.subtract(group.items.map(\.id))
    }

    /// Quantas cópias do grupo ficariam intactas se a seleção atual fosse
    /// executada.
    func keptCount(in group: DuplicateGroup) -> Int {
        group.items.filter { !selection.contains($0.id) }.count
    }

    var selectedEntries: [LargeFileEntry] {
        groups.flatMap(\.items).filter { selection.contains($0.id) }
    }

    var selectedCount: Int { selectedEntries.count }

    var selectedTotalSize: Int64 {
        selectedEntries.reduce(0) { $0 + $1.sizeOnDisk }
    }

    /// Grupos em que **nenhuma** cópia foi preservada.
    ///
    /// Este é o único caso em que remover significa perder o conteúdo, e é o
    /// que o diálogo de confirmação nomeia um a um.
    var groupsWithoutKeeper: [DuplicateGroup] {
        groups.filter { group in
            !group.items.isEmpty && group.items.allSatisfy { selection.contains($0.id) }
        }
    }

    var canRunRemoval: Bool {
        !selectedEntries.isEmpty && !isRemoving && !isSearching
    }

    // MARK: - Remoção

    func beginRemoval() {
        let entries = selectedEntries
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
        let entries = selectedEntries
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
                kind: .duplicateReview
            )
            report = outcome.report

            // Os grupos são reconstruídos a partir do que de fato saiu do
            // disco: um grupo que ficou com uma cópia só deixou de ser
            // duplicata, e um que ficou vazio simplesmente desapareceu.
            rebuildAfterRemoval(report: outcome.report)
        } catch is CancellationError {
            errorMessage = "A remoção foi interrompida. Algumas cópias podem já ter sido movidas para a Lixeira — execute a busca de novo para conferir o que sobrou."
        } catch {
            errorMessage = Self.message(for: error)
        }

        isRemoving = false
        removalTask = nil
    }

    private func rebuildAfterRemoval(report: RemovalReport) {
        let removed = Set(report.outcomes
            .filter { $0.disposition == .movedToTrash || $0.disposition == .permanentlyDeleted }
            .map(\.url.path))

        guard !removed.isEmpty else { return }

        var rebuilt: [DuplicateGroup] = []
        for group in groups {
            let survivors = group.items.filter { !removed.contains($0.url.path) }
            selection.subtract(group.items.map(\.id).filter { removed.contains($0) })
            guard survivors.count > 1 else { continue }

            rebuilt.append(
                DuplicateGroup(
                    digest: group.digest,
                    sizeOnDisk: group.sizeOnDisk,
                    items: survivors,
                    newest: survivors.compactMap(\.modificationDate).max(),
                    oldest: survivors.compactMap(\.modificationDate).min(),
                    isInSyncedFolder: survivors.contains(where: \.isInSyncedFolder),
                    containsHardLinks: group.containsHardLinks
                )
            )
        }

        groups = rebuilt
    }

    /// Converte uma cópia marcada em candidato de limpeza.
    ///
    /// A consequência carrega o risco real da categoria: em duplicados, a
    /// remoção pode ser o último ponto onde aquele conteúdo ainda existe.
    static func candidate(for item: LargeFileEntry) -> CleanupCandidate {
        CleanupCandidate(
            url: item.url,
            category: .duplicates,
            reason: "Cópia com conteúdo idêntico confirmado por hash SHA-256.",
            confidence: .certain,
            sizeOnDisk: item.sizeOnDisk,
            isDirectory: false,
            consequence: "O conteúdo é igual ao de outra cópia do grupo. Confirme que a cópia que você preservou está no lugar antes de continuar.",
            isInSyncedFolder: item.isInSyncedFolder
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
