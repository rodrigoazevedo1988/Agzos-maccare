import Foundation
import MacCareCore
import Observation

/// ## Estado da tela de limpeza inteligente
///
/// Três decisões delimitam este view model:
///
/// 1. **Nada acontece ao abrir a tela.** `result` começa `nil` e só é
///    preenchido por `startAnalysis(environment:)`, acionado pelo usuário
///    (PRD §24). Nenhuma `Task` de leitura é criada no `init`.
/// 2. **A seleção inicial vem do núcleo, não da tela.** `applyPreselection`
///    usa `isPreselectedByDefault` do próprio `CleanupCandidate` — a regra de
///    "confirmado e sem categoria de risco" mora em um lugar só.
/// 3. **Nada é removido sem passar por `AppEnvironment`.** Este arquivo não
///    conhece `SafeFileRemover`, `PathGuard` nem `FileSystem`; ele só entrega
///    candidatos ao ambiente e renderiza o relatório que volta.
@Observable
@MainActor
final class SmartCareModel {

    // MARK: - Estado observável

    private(set) var isAnalyzing = false
    private(set) var isCleaning = false
    private(set) var progress = ScanProgress()
    private(set) var result: SmartScanResult?
    private(set) var report: RemovalReport?
    private(set) var wasCancelled = false

    /// Identificadores (`UUID`) dos candidatos marcados pelo usuário.
    var selection: Set<UUID> = []
    /// Categorias abertas. Começa com as que têm itens pré-selecionados, para
    /// que a seleção inicial já fique visível em vez de escondida num
    /// disclosure fechado.
    var expandedGroupIDs: Set<String> = []
    var errorMessage: String?

    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?

    init() {}

    // MARK: - Análise

    func startAnalysis(environment: AppEnvironment) {
        guard !isAnalyzing else { return }

        analysisTask?.cancel()
        isAnalyzing = true
        wasCancelled = false
        errorMessage = nil
        report = nil
        result = nil
        selection = []
        expandedGroupIDs = []
        progress = ScanProgress()

        analysisTask = Task { [weak self] in
            await self?.runAnalysis(environment: environment)
        }
    }

    private func runAnalysis(environment: AppEnvironment) async {
        // O callback é `@Sendable`: a varredura roda fora do MainActor e cada
        // atualização precisa voltar para ele antes de tocar em estado
        // observável.
        let handler: @Sendable (ScanProgress) -> Void = { [weak self] update in
            Task { @MainActor in
                self?.progress = update
            }
        }

        do {
            let scan = try await environment.runSmartScan(progress: handler)
            result = scan
            progress = scan.progress
            applyPreselection(groups: scan.groups)
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            errorMessage = Self.message(for: error)
        }

        isAnalyzing = false
        analysisTask = nil
    }

    /// Reproduz a política de seleção inicial do núcleo.
    ///
    /// O mesmo critério vale para abrir o disclosure: se nada foi marcado, o
    /// usuário veria uma lista fechada sem nenhum indício do que o app
    /// considera seguro.
    private func applyPreselection(groups: [CleanupCategoryGroup]) {
        var preselected: Set<UUID> = []
        var expanded: Set<String> = []

        for group in groups {
            let marked = group.candidates.filter(\.isPreselectedByDefault)
            preselected.formUnion(marked.map(\.id))
            if !marked.isEmpty { expanded.insert(group.id) }
        }

        selection = preselected
        expandedGroupIDs = expanded
    }

    func cancelAnalysis() {
        guard isAnalyzing else { return }
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
        wasCancelled = true
    }

    // MARK: - Seleção

    func isSelected(_ candidate: CleanupCandidate) -> Bool {
        selection.contains(candidate.id)
    }

    func setSelected(_ isOn: Bool, for candidate: CleanupCandidate) {
        if isOn {
            selection.insert(candidate.id)
        } else {
            selection.remove(candidate.id)
        }
    }

    func setGroup(_ group: CleanupCategoryGroup, selected: Bool) {
        for candidate in group.candidates {
            if selected {
                selection.insert(candidate.id)
            } else {
                selection.remove(candidate.id)
            }
        }
    }

    func isGroupSelected(_ group: CleanupCategoryGroup) -> Bool {
        group.candidates.allSatisfy { selection.contains($0.id) }
    }

    func selectedCount(in group: CleanupCategoryGroup) -> Int {
        group.candidates.reduce(into: 0) { partial, candidate in
            if selection.contains(candidate.id) { partial += 1 }
        }
    }

    // MARK: - Totais

    var allCandidates: [CleanupCandidate] {
        result?.groups.flatMap(\.candidates) ?? []
    }

    var selectedCandidates: [CleanupCandidate] {
        allCandidates.filter { selection.contains($0.id) }
    }

    /// Soma apenas de itens com tamanho conhecido. Itens não medidos são
    /// contabilizados à parte — somar zero para eles inflaria a confiança da
    /// estimativa sem acrescentar precisão alguma.
    var selectedTotalSize: Int64 {
        selectedCandidates.compactMap(\.sizeOnDisk).reduce(0, +)
    }

    var selectedUnmeasuredCount: Int {
        selectedCandidates.filter { $0.sizeOnDisk == nil }.count
    }

    /// Categorias da seleção que exigem confirmação reforçada.
    var reinforcedCategories: [CleanupCategory] {
        var seen: Set<CleanupCategory> = []
        return selectedCandidates.compactMap { candidate in
            guard candidate.category.requiresReinforcedConfirmation else { return nil }
            return seen.insert(candidate.category).inserted ? candidate.category : nil
        }
    }

    var requiresReinforcedConfirmation: Bool { !reinforcedCategories.isEmpty }

    var canRunCleanup: Bool {
        !selectedCandidates.isEmpty && !isCleaning && !isAnalyzing
    }

    // MARK: - Execução

    func startCleanup(environment: AppEnvironment) {
        let candidates = selectedCandidates
        guard !candidates.isEmpty, !isCleaning else { return }

        cleanupTask?.cancel()
        isCleaning = true
        errorMessage = nil
        report = nil

        cleanupTask = Task { [weak self] in
            await self?.runCleanup(candidates: candidates, environment: environment)
        }
    }

    private func runCleanup(candidates: [CleanupCandidate], environment: AppEnvironment) async {
        do {
            let outcome = try await environment.performCleanup(
                candidates: candidates,
                strategy: .moveToTrash,
                kind: .smartCleanup
            )
            report = outcome.report
            // O resultado antigo descreve um disco que já mudou. Em vez de
            // fingir que os itens ainda existem, eles saem da seleção e a tela
            // passa a exibir o relatório.
            selection.subtract(candidates.map(\.id))
        } catch is CancellationError {
            // O plano é executado em lotes e pode ser interrompido no meio.
            // Dizer "nada aconteceu" seria falso: parte dos itens pode já
            // estar na Lixeira, e a orientação correta é reanalisar.
            errorMessage = "A limpeza foi interrompida. Alguns itens podem já ter sido movidos para a Lixeira — execute a análise novamente para conferir o que sobrou."
        } catch {
            errorMessage = Self.message(for: error)
        }

        isCleaning = false
        cleanupTask = nil
    }

    func dismissReport() {
        report = nil
    }

    // MARK: - Apoio

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
