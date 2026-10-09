import Foundation

/// Como um item aprovado será removido.
public enum RemovalStrategy: String, Codable, Sendable, CaseIterable {
    /// Padrão. Move para a Lixeira — reversível pelo usuário a qualquer momento.
    case moveToTrash
    /// Remove definitivamente. Exige confirmação reforçada *e* a flag
    /// explícita `allowPermanentDeletion` no plano.
    case permanentlyDelete
    /// Simulação: produz o relatório completo sem modificar nada no disco.
    case simulate

    public var label: String {
        switch self {
        case .moveToTrash: return "Mover para a Lixeira"
        case .permanentlyDelete: return "Excluir definitivamente"
        case .simulate: return "Simular sem alterar arquivos"
        }
    }

    public var isReversible: Bool {
        self == .moveToTrash || self == .simulate
    }
}

/// Nível de confirmação exigido para um conjunto de itens.
public enum ConfirmationKind: String, Codable, Sendable {
    /// Confirmação padrão para itens regeneráveis (cache, logs, temporários).
    case standard
    /// Confirmação reforçada, exigida por categorias que podem conter
    /// dados do usuário: Lixeira, duplicados, arquivos grandes, downloads.
    case full
}

/// Observação de arquitetura: a inicialização de `ConfirmedSelection` é
/// lançadora (`throws`) — o único caminho para construir um plano passa por
/// ela, e ela recusa combinações inseguras. Não existe como montar um plano
/// executável sem confirmação.
public enum RemovalPlanError: Error, LocalizedError, Equatable {
    case emptySelection
    case insufficientConfirmation(required: ConfirmationKind, provided: ConfirmationKind)
    case permanentDeletionNotAuthorized
    case nothingSelected

    public var errorDescription: String? {
        switch self {
        case .emptySelection, .nothingSelected:
            return "Nenhum item foi selecionado para remoção."
        case .insufficientConfirmation(let required, let provided):
            return "Esta operação exige confirmação \(required == .full ? "reforçada" : "padrão") e recebeu confirmação \(provided == .full ? "reforçada" : "padrão")."
        case .permanentDeletionNotAuthorized:
            return "Exclusão definitiva não autorizada neste plano. Prefira mover para a Lixeira."
        }
    }
}

/// Conjunto de itens que o usuário viu e confirmou explicitamente.
///
/// Existe como tipo próprio, e não como um array solto, por uma razão: a
/// política de confirmação vira uma *restrição de inicialização*. Não existe
/// `RemovalPlan` executável no sistema que não tenha passado por aqui.
public struct ConfirmedSelection: Sendable {

    public let items: [CleanupCandidate]
    public let kind: ConfirmationKind
    public let confirmedAt: Date

    /// Inicializador que aplica as regras de confirmação do PRD §7 e §8.
    /// - Throws: `RemovalPlanError` quando a seleção está vazia ou quando a
    ///   confiança exigida não foi atingida.
    public init(
        items: [CleanupCandidate],
        kind: ConfirmationKind,
        confirmedAt: Date = Date()
    ) throws {
        guard !items.isEmpty else { throw RemovalPlanError.emptySelection }

        let requiresFull = items.contains { $0.category.requiresReinforcedConfirmation }
        if requiresFull && kind != .full {
            throw RemovalPlanError.insufficientConfirmation(required: .full, provided: kind)
        }

        self.items = items
        self.kind = kind
        self.confirmedAt = confirmedAt
    }
}

/// Plano de remoção completo e pronto para execução.
public struct RemovalPlan: Sendable {
    public let selection: ConfirmedSelection
    public let strategy: RemovalStrategy
    /// Autorização explícita para apagar em vez de mandar para a Lixeira.
    public let allowPermanentDeletion: Bool

    public init(
        selection: ConfirmedSelection,
        strategy: RemovalStrategy = .moveToTrash,
        allowPermanentDeletion: Bool = false
    ) throws {
        if strategy == .permanentlyDelete && !allowPermanentDeletion {
            throw RemovalPlanError.permanentDeletionNotAuthorized
        }
        self.selection = selection
        self.strategy = strategy
        self.allowPermanentDeletion = allowPermanentDeletion
    }
}

/// O que aconteceu com um item específico.
public struct RemovalOutcome: Identifiable, Hashable, Codable, Sendable {
    public enum Disposition: String, Codable, Sendable {
        case movedToTrash
        case permanentlyDeleted
        case skipped
        case failed
    }

    public let id: UUID
    public let url: URL
    public let disposition: Disposition
    /// Tamanho em disco medido *antes* da operação.
    public let measuredSize: Int64?
    public let reason: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        disposition: Disposition,
        measuredSize: Int64? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.url = url
        self.disposition = disposition
        self.measuredSize = measuredSize
        self.reason = reason
    }
}

/// Contabilidade de espaço exigida pelo PRD §19.
///
/// A distinção entre "liberado" e "liberado mas não confirmável" não é
/// vaidade: mover para a Lixeira quase nunca reduz o espaço do volume de
/// forma mensurável imediatamente, porque a Lixeira vive no mesmo disco. Se o
/// app somasse "12 GB liberados" quando nada mudou no disco, estaria mentindo.
public struct SpaceAccounting: Hashable, Codable, Sendable {
    /// Soma dos candidatos identificados pela análise.
    public let identified: Int64
    /// Soma dos itens que o usuário marcou.
    public let selected: Int64
    /// Espaço cuja redução foi verificada após a operação.
    public let releasedConfirmed: Int64
    /// Espaço processado cuja redução não pôde ser confirmada com segurança.
    public let releasedUnconfirmed: Int64
    /// Total de itens que falharam.
    public let failedItems: Int

    public init(
        identified: Int64 = 0,
        selected: Int64 = 0,
        releasedConfirmed: Int64 = 0,
        releasedUnconfirmed: Int64 = 0,
        failedItems: Int = 0
    ) {
        self.identified = identified
        self.selected = selected
        self.releasedConfirmed = releasedConfirmed
        self.releasedUnconfirmed = releasedUnconfirmed
        self.failedItems = failedItems
    }
}

/// Resultado completo de uma execução de limpeza.
public struct RemovalReport: Hashable, Codable, Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let strategy: RemovalStrategy
    public let outcomes: [RemovalOutcome]
    public let accounting: SpaceAccounting

    public var movedToTrash: [RemovalOutcome] { outcomes.filter { $0.disposition == .movedToTrash } }
    public var deleted: [RemovalOutcome] { outcomes.filter { $0.disposition == .permanentlyDeleted } }
    public var skipped: [RemovalOutcome] { outcomes.filter { $0.disposition == .skipped } }
    public var failed: [RemovalOutcome] { outcomes.filter { $0.disposition == .failed } }

    public var isPartialSuccess: Bool { !failed.isEmpty && !skipped.isEmpty }
    public var isFullySuccessful: Bool { failed.isEmpty && skipped.isEmpty }

    public var summary: String {
        let trash = movedToTrash.count
        let deletedCount = deleted.count
        let skip = skipped.count
        let fail = failed.count
        switch (trash, deletedCount, skip, fail) {
        case (0, 0, 0, 0):
            return "Nenhum item foi processado."
        default:
            var parts: [String] = []
            if trash > 0 { parts.append("\(trash) movidos para a Lixeira") }
            if deletedCount > 0 { parts.append("\(deletedCount) excluídos definitivamente") }
            if skip > 0 { parts.append("\(skip) ignorados por segurança") }
            if fail > 0 { parts.append("\(fail) falharam") }
            return parts.joined(separator: ", ") + "."
        }
    }
}

/// Serviço central responsável por executar remoções validadas.
///
/// Toda operação destrutiva do MacCare passa por aqui. A classe é um `actor`
/// para serializar as operações: duas limpezas simultâneas não podem competir
/// pelos mesmos arquivos, e o relatório de cada uma precisa ser consistente.
///
/// Cada item é revalidado no momento da execução — e não apenas na análise.
/// O tempo entre "analisar" e "limpar" é a janela real de ataque do sistema,
/// e é exatamente onde um link simbólico trocado por outro processo seria
/// explorado. Revalidar aqui fecha essa janela.
public actor SafeFileRemover {

    private let guardrail: PathGuard
    private let maxConcurrentOperations: Int
    private let fs: FileSystem

    public init(
        guardrail: PathGuard,
        maxConcurrentOperations: Int = 4,
        fs: FileSystem = .live
    ) {
        self.guardrail = guardrail
        self.maxConcurrentOperations = max(1, maxConcurrentOperations)
        self.fs = fs
    }

    /// Executa um plano já confirmado.
    ///
    /// - Returns: relatório com o destino de cada item e a contabilidade de espaço.
    /// - Throws: `CancellationError` se a tarefa for cancelada.
    public func execute(_ plan: RemovalPlan) async throws -> RemovalReport {
        let startedAt = Date()

        // Validação defensiva: confirma que a estratégia do plano é coerente
        // com a autorização antes de tocar em qualquer arquivo.
        if plan.strategy == .permanentlyDelete && !plan.allowPermanentDeletion {
            throw RemovalPlanError.permanentDeletionNotAuthorized
        }

        let volumeFreeBefore = fs.volumeAvailableCapacity()
        let volumeFreeAfter: Int64?
        var outcomes: [RemovalOutcome] = []
        outcomes.reserveCapacity(plan.selection.items.count)

        // Janela limitada de concorrência: alta o suficiente para I/O não
        // bloquear a interface, baixa o bastante para não saturar o disco.
        var pending: [CleanupCandidate] = plan.selection.items
        while !pending.isEmpty {
            try Task.checkCancellation()
            let batch = Array(pending.prefix(maxConcurrentOperations))
            pending.removeFirst(batch.count)

            let batchOutcomes = await withTaskGroup(of: RemovalOutcome.self) { group in
                for candidate in batch {
                    group.addTask { self.process(candidate, strategy: plan.strategy) }
                }
                var collected: [RemovalOutcome] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            outcomes.append(contentsOf: batchOutcomes)
        }

        // Espaço livre só é comparável quando a estratégia altera o volume
        // de fato. Simulação nunca produz essa leitura.
        if plan.strategy != .simulate {
            volumeFreeAfter = fs.volumeAvailableCapacity()
        } else {
            volumeFreeAfter = nil
        }

        let accounting = SpaceAccounting(
            identified: plan.selection.items.compactMap(\.sizeOnDisk).reduce(0, +),
            selected: outcomes.filter { $0.disposition == .movedToTrash || $0.disposition == .permanentlyDeleted }
                .compactMap(\.measuredSize).reduce(0, +),
            releasedConfirmed: confirmedRelease(
                strategy: plan.strategy,
                before: volumeFreeBefore,
                after: volumeFreeAfter,
                outcomes: outcomes
            ),
            releasedUnconfirmed: unconfirmedRelease(outcomes),
            failedItems: outcomes.filter { $0.disposition == .failed }.count
        )

        return RemovalReport(
            startedAt: startedAt,
            finishedAt: Date(),
            strategy: plan.strategy,
            outcomes: outcomes,
            accounting: accounting
        )
    }

    // MARK: - Processamento de um item

    private nonisolated func process(_ candidate: CleanupCandidate, strategy: RemovalStrategy) async -> RemovalOutcome {
        let url = candidate.url

        // Revalidação no momento da execução. Ver comentário de classe.
        switch guardrail.evaluate(url) {
        case .denied(let code):
            return RemovalOutcome(
                url: url,
                disposition: .skipped,
                measuredSize: candidate.sizeOnDisk,
                reason: code.explanation
            )
        case .allowed(let resolved, let isSymlink):
            if isSymlink && strategy == .permanentlyDelete {
                return RemovalOutcome(
                    url: url,
                    disposition: .skipped,
                    measuredSize: candidate.sizeOnDisk,
                    reason: "Item é um link simbólico. Removemos apenas o link, nunca o destino — e isso exigiria confirmação separada."
                )
            }
            return performRemoval(at: resolved, original: url, candidate: candidate, strategy: strategy)
        }
    }

    private nonisolated func performRemoval(
        at url: URL,
        original: URL,
        candidate: CleanupCandidate,
        strategy: RemovalStrategy
    ) -> RemovalOutcome {
        // Medição antes da remoção: depois do `unlink` o tamanho já não existe.
        let size = fs.allocatedSize(of: url)

        switch strategy {
        case .simulate:
            return RemovalOutcome(url: original, disposition: .skipped, measuredSize: size,
                                  reason: "Simulação: nada foi alterado.")

        case .moveToTrash:
            do {
                try fs.moveToTrash(url)
                return RemovalOutcome(url: original, disposition: .movedToTrash, measuredSize: size,
                                      reason: "Enviado para a Lixeira. Você pode restaurar.")
            } catch {
                // Sem fallback silencioso para exclusão permanente: o PRD §8 é
                // explícito. Se a Lixeira falhou, o usuário decide o próximo passo.
                return RemovalOutcome(
                    url: original,
                    disposition: .failed,
                    measuredSize: size,
                    reason: "Não foi possível mover para a Lixeira: \(error.localizedDescription). O arquivo foi mantido intacto."
                )
            }

        case .permanentlyDelete:
            do {
                try fs.remove(at: url)
                return RemovalOutcome(url: original, disposition: .permanentlyDeleted, measuredSize: size,
                                      reason: "Excluído definitivamente. Esta operação não pode ser desfeita.")
            } catch {
                return RemovalOutcome(url: original, disposition: .failed, measuredSize: size,
                                  reason: "Falha ao excluir: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Contabilidade de espaço

    /// Espaço livre realmente confirmado pela medição antes/depois no volume.
    ///
    /// Quando a diferença é negativa (outro processo escreveu mais dados), o
    /// resultado correto é zero, não um número negativo. O usuário não deve ver
    /// "-2 GB liberados".
    private nonisolated func confirmedRelease(
        strategy: RemovalStrategy,
        before: Int64,
        after: Int64?,
        outcomes: [RemovalOutcome]
    ) -> Int64 {
        guard strategy == .permanentlyDelete, let after else { return 0 }
        let delta = after - before
        guard delta > 0 else { return 0 }
        return min(delta, outcomes.compactMap(\.measuredSize).reduce(0, +))
    }

    /// Espaço processado que não pode ser confirmado, tipicamente por ter ido
    /// para a Lixeira (que continua ocupando o mesmo volume).
    private nonisolated func unconfirmedRelease(_ outcomes: [RemovalOutcome]) -> Int64 {
        outcomes
            .filter { $0.disposition == .movedToTrash }
            .compactMap(\.measuredSize)
            .reduce(0, +)
    }
}
