import AppKit
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
    // MARK: - Desinstalação

    /// Autoriza a desinstalação de UM aplicativo.
    ///
    /// Não usa o `pathGuard` de limpeza: `/Applications` continua protegido
    /// para tudo o mais. A autorização permite só o bundle escolhido e os
    /// residuais dele em `~/Library` — e só pela Lixeira.
    public nonisolated static func uninstallAuthorization(
        for application: ApplicationEntry
    ) -> Result<AppUninstallAuthorization, AppUninstallError> {
        Result {
            try AppUninstallAuthorization(
                bundle: application.url,
                isRunning: AppEnvironment.isApplicationRunning
            )
        }.mapError { ($0 as? AppUninstallError) ?? .invalidBundle }
    }

    /// Há algum processo aberto com este identificador?
    public nonisolated static let isApplicationRunning: @Sendable (String) -> Bool = { identifier in
        !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }

    /// Executa a desinstalação pela autorização dedicada.
    ///
    /// A autorização é **recriada aqui**, no momento da execução: se o app foi
    /// aberto, trocado por um link ou movido desde que a folha abriu, a
    /// execução inteira é recusada. Depois disso, o `SafeFileRemover` ainda
    /// revalida cada caminho item a item.
    public func performUninstall(
        application: ApplicationEntry,
        candidates: [CleanupCandidate],
        confirmation: ConfirmationKind
    ) async throws -> (report: RemovalReport, record: OperationRecord) {
        guard !candidates.isEmpty else { throw RemovalPlanError.emptySelection }

        let authorization = try Self.uninstallAuthorization(for: application).get()
        let selection = try ConfirmedSelection(items: candidates, kind: confirmation)
        // Só Lixeira: a autorização de desinstalação recusa exclusão definitiva.
        let plan = try RemovalPlan(selection: selection, strategy: .moveToTrash)
        let report = try await SafeFileRemover(guardrail: authorization).execute(plan)
        let record = try await log(report: report, kind: .applicationRemoval, strategy: .moveToTrash, itemCount: candidates.count)
        return (report, record)
    }

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
        let record = try await log(report: report, kind: kind, strategy: strategy, itemCount: candidates.count)
        return (report, record)
    }

    private func log(
        report: RemovalReport,
        kind: OperationKind,
        strategy: RemovalStrategy,
        itemCount: Int
    ) async throws -> OperationRecord {
        let record = OperationRecord(
            performedAt: report.finishedAt,
            kind: kind,
            strategy: strategy.label,
            itemCount: itemCount,
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
        return record
    }

    public enum EnvironmentError: Error, LocalizedError {
        case noScope

        public var errorDescription: String? {
            "Nenhuma pasta foi autorizada para análise. Abra as Configurações e escolha o escopo."
        }
    }
}
