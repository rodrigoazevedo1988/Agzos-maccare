import Foundation
import MacCareCore
import Observation

/// ## Contêiner de dependências
///
/// Um único lugar onde os serviços do núcleo são instanciados e injetados na
/// interface. Ele existe por dois motivos práticos:
///
/// 1. **Testabilidade de interface.** Uma tela que recebe `SmartScanCoordinator`
///    do ambiente pode ser testada com um dublê; uma que cria o coordinator
///    dentro do próprio `init` não pode.
/// 2. **Escopo explícito.** `PathGuard` e `SafeFileRemover` dependem do escopo
///    autorizado. Construí-los aqui significa que o escopo é decidido **uma**
///    vez, no lugar certo, e todas as telas obedecem à mesma regra.
@Observable
@MainActor
public final class AppEnvironment {

    // MARK: - Serviços de leitura (independentes do escopo de limpeza)

    public let metrics = HostMetricsCollector()
    public let applications = ApplicationCatalog()
    public let startupItems = StartupItemScanner()

    // MARK: - Escopo de análise e limpeza

    /// O escopo atual. Mutável porque o usuário pode decidir incluir ou não
    /// `~/Downloads` — mas nunca o MacCare amplia o escopo sozinho.
    public var scope: AnalysisScope? = AnalysisScope.standard() {
        didSet { rebuildCleaningServices() }
    }

    public private(set) var pathGuard: PathGuard
    public private(set) var remover: SafeFileRemover!
    public private(set) var scanner: DirectoryScanner
    public private(set) var duplicates: DuplicateFinder

    // MARK: - Persistência

    public let operationLog: JSONLOperationLog

    /// User settings e paths are stored in App Support, which in a sandboxed
    /// build resolves to the container.
    public init() {
        self.operationLog = JSONLOperationLog(fileURL: JSONLOperationLog.defaultLocation())
        self.pathGuard = PathGuard(allowedRoots: [], ownBundle: Bundle.main.bundleURL)
        self.scanner = DirectoryScanner()
        self.duplicates = DuplicateFinder()
        self.remover = SafeFileRemover(guardrail: self.pathGuard)
        rebuildCleaningServices()
    }

    /// Recria os serviços que dependem do escopo.
    ///
    /// Importante: o `PathGuard` é **reconstruído junto**. Se o escopo encolhe,
    /// as autorizações antigas morrem — não há estado obsoleto capaz de
    /// autorizar uma remoção que o usuário já revogou.
    private func rebuildCleaningServices() {
        let guardrail = (scope?.makePathGuard(ownBundle: Bundle.main.bundleURL)) ?? .denyAll
        self.pathGuard = guardrail
        self.remover = SafeFileRemover(guardrail: guardrail)
        self.scanner = DirectoryScanner()
        self.duplicates = DuplicateFinder()
    }

    // MARK: - Ações de alto nível

    /// Executa a análise consolidada.
    public func runSmartScan(
        progress: @Sendable @escaping (ScanProgress) -> Void = { _ in }
    ) async throws -> SmartScanResult {
        guard let scope else {
            throw EnvironmentError.noScope
        }
        return try await SmartScanCoordinator().run(scope: scope, progress: progress)
    }

    /// Monta e executa um plano de limpeza a partir de uma seleção do usuário.
    ///
    /// A confirmação é exigida aqui, no serviço, e não apenas na interface: é
    /// a única forma de garantir que nenhuma tela consiga executar uma remoção
    /// sem passar por este ponto.
    public func performCleanup(
        candidates: [CleanupCandidate],
        strategy: RemovalStrategy,
        kind: OperationKind = .smartCleanup
    ) async throws -> (report: RemovalReport, record: OperationRecord) {
        guard !candidates.isEmpty else { throw RemovalPlanError.emptySelection }

        let needsFull = candidates.contains { $0.category.requiresReinforcedConfirmation }
        let selection = try ConfirmedSelection(
            items: candidates,
            kind: needsFull ? .full : .standard
        )
        let plan = try RemovalPlan(
            selection: selection,
            strategy: strategy,
            allowPermanentDeletion: strategy == .permanentlyDelete
        )

        let report = try await remover.execute(plan)
        let record = OperationRecord(
            performedAt: report.finishedAt,
            kind: kind,
            strategy: strategy.label,
            itemCount: candidates.count,
            succeededCount: report.movedToTrash.count + report.deleted.count,
            skippedCount: report.skipped.count,
            failedCount: report.failed.count,
            affectedPaths: report.outcomes
                .filter { $0.disposition == .movedToTrash || $0.disposition == .permanentlyDeleted }
                .map(\.url.path),
            accounting: report.accounting,
            notes: report.failed.compactMap { "\($0.url.lastPathComponent): \($0.reason ?? "sem detalhe")" }
        )
        try await operationLog.append(record)

        return (report, record)
    }

    public enum EnvironmentError: Error, LocalizedError {
        case noScope

        public var errorDescription: String? {
            "Nenhuma pasta foi autorizada para análise. Abra as Configurações e escolha o escopo."
        }
    }
}
