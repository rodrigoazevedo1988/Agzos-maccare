import Foundation

/// Tipo de operação registrada no histórico.
public enum OperationKind: String, Codable, Sendable, CaseIterable {
    case smartCleanup
    case largeFileReview
    case duplicateReview
    case applicationRemoval
    case securityCheck
    case storageScan

    public var title: String {
        switch self {
        case .smartCleanup: return "Limpeza inteligente"
        case .largeFileReview: return "Revisão de arquivos grandes"
        case .duplicateReview: return "Revisão de duplicados"
        case .applicationRemoval: return "Desinstalação"
        case .securityCheck: return "Verificação de segurança"
        case .storageScan: return "Análise de armazenamento"
        }
    }

    public var symbolName: String {
        switch self {
        case .smartCleanup: return "sparkles"
        case .largeFileReview: return "doc.text.magnifyingglass"
        case .duplicateReview: return "square.on.square"
        case .applicationRemoval: return "trash.slash"
        case .securityCheck: return "checkmark.shield"
        case .storageScan: return "chart.pie"
        }
    }
}

/// Registro imutável de uma operação executada pelo aplicativo.
///
/// O PRD §19 é rigoroso sobre o que pode ser guardado: "não armazenar conteúdo
/// de arquivos", "não registrar tokens, senhas ou dados sensíveis". Por isso o
/// registro guarda **caminhos e contagens**, nunca conteúdo, e a exportação
/// tem uma rotina que remove a parte pessoal (o nome do usuário no caminho).
public struct OperationRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let performedAt: Date
    public let kind: OperationKind
    public let strategy: String
    public let itemCount: Int
    public let succeededCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    /// Caminhos envolvidos, para permitir desfazer/auditar.
    public let affectedPaths: [String]
    public let accounting: SpaceAccounting
    public let notes: [String]

    public init(
        id: UUID = UUID(),
        performedAt: Date,
        kind: OperationKind,
        strategy: String,
        itemCount: Int,
        succeededCount: Int,
        skippedCount: Int,
        failedCount: Int,
        affectedPaths: [String],
        accounting: SpaceAccounting,
        notes: [String]
    ) {
        self.id = id
        self.performedAt = performedAt
        self.kind = kind
        self.strategy = strategy
        self.itemCount = itemCount
        self.succeededCount = succeededCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.accounting = accounting
        self.affectedPaths = affectedPaths
        self.notes = notes
    }

    /// Versão segura para exportação: remove o nome do usuário dos caminhos
    /// e o prefixo `/Users`, trocando por `~`.
    public func redacted(homePath: String?) -> OperationRecord {
        guard let homePath, !homePath.isEmpty else { return self }
        return OperationRecord(
            id: id,
            performedAt: performedAt,
            kind: kind,
            strategy: strategy,
            itemCount: itemCount,
            succeededCount: succeededCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            affectedPaths: affectedPaths.map { $0.replacingOccurrences(of: homePath, with: "~") },
            accounting: accounting,
            notes: notes
        )
    }
}
