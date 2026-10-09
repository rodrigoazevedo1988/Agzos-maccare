import Foundation

/// Grau de certeza sobre a associação entre um item e a limpeza.
///
/// O PRD (§7, §12) é explícito: "não classificar automaticamente qualquer arquivo
/// grande, antigo ou desconhecido como lixo". A confiança é o que separa
/// "isto é um cache regenerável do app X" de "isto está numa pasta que eu não
/// entendo" — e é o que decide se o item vem pré-selecionado.
public enum Confidence: String, Codable, Sendable, CaseIterable, Comparable {
    /// Associação verificada por regra determinística. Pode vir pré-selecionado.
    case certain
    /// Associação provável (padrão de nome conhecido, mas sem prova de posse).
    /// Sempre desmarcado por padrão.
    case likely
    /// Apenas um candidato para revisão humana. Nunca pré-selecionado.
    case uncertain

    private var order: Int {
        switch self {
        case .certain: return 2
        case .likely: return 1
        case .uncertain: return 0
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.order < rhs.order
    }

    public var label: String {
        switch self {
        case .certain: return "Confirmado"
        case .likely: return "Provável"
        case .uncertain: return "Para revisar"
        }
    }
}

/// Categoria de um candidato à limpeza.
public enum CleanupCategory: String, Codable, Sendable, CaseIterable {
    case applicationCache
    case temporaryFiles
    case oldLogs
    case trash
    case applicationLeftovers
    case browserData
    case largeFiles
    case duplicates
    case oldDownloads
    case developerData
    case other

    public var title: String {
        switch self {
        case .applicationCache: return "Cache de aplicativos"
        case .temporaryFiles: return "Arquivos temporários"
        case .oldLogs: return "Logs antigos"
        case .trash: return "Lixeira"
        case .applicationLeftovers: return "Resíduos de aplicativos"
        case .browserData: return "Dados de navegação"
        case .largeFiles: return "Arquivos grandes"
        case .duplicates: return "Duplicados"
        case .oldDownloads: return "Downloads antigos"
        case .developerData: return "Dados de desenvolvimento"
        case .other: return "Outros candidatos"
        }
    }

    public var symbolName: String {
        switch self {
        case .applicationCache: return "shippingbox"
        case .temporaryFiles: return "doc.badge.clock"
        case .oldLogs: return "text.alignleft"
        case .trash: return "trash"
        case .applicationLeftovers: return "app.badge.minus"
        case .browserData: return "safari"
        case .largeFiles: return "externaldrive.badge.exclamationmark"
        case .duplicates: return "square.on.square"
        case .oldDownloads: return "arrow.down.circle"
        case .developerData: return "chevron.left.forwardslash.chevron.right"
        case .other: return "sparkle.magnifyingglass"
        }
    }

    /// Categorias que representam risco real de perda de dados do usuário.
    /// Entram no plano de limpeza com confirmação reforçada e nunca com
    /// seleção automática — a Lixeira em si, duplicados e downloads antigos.
    public var requiresReinforcedConfirmation: Bool {
        switch self {
        case .trash, .duplicates, .oldDownloads, .largeFiles, .browserData: return true
        default: return false
        }
    }

    /// Verdadeiro quando a categoria se refere a algo gerado por um aplicativo
    /// e portanto regenerável — o que torna a limpeza reversível na prática.
    public var isRegenerable: Bool {
        switch self {
        case .applicationCache, .temporaryFiles, .oldLogs, .browserData, .trash, .applicationLeftovers:
            return true
        case .largeFiles, .duplicates, .oldDownloads, .developerData, .other:
            return false
        }
    }
}

/// Um item que a análise identificou como candidato.
///
/// O tipo é deliberadamente "burro": ele carrega o *fato* (caminho, tamanho,
/// categoria, motivo) e nenhuma permissão para apagar. A decisão de executar
/// vive exclusivamente em `SafeFileRemover`, depois de `PathGuard` aprovar.
public struct CleanupCandidate: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var url: URL
    public var category: CleanupCategory
    /// Regra que identificou o item. Legível, exibido antes de qualquer ação.
    public var reason: String
    public var confidence: Confidence
    /// Tamanho ocupado em disco quando mensurável. `nil` significa
    /// "não foi possível medir" — nunca zero.
    public var sizeOnDisk: Int64?
    public var isDirectory: Bool
    /// Consequência conhecida, exibida na pré-visualização (ex.: "abre reaparecer na próxima execução").
    public var consequence: String?
    /// Indica que o item está em diretório sincronizado (iCloud, Dropbox, etc.).
    public var isInSyncedFolder: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        category: CleanupCategory,
        reason: String,
        confidence: Confidence,
        sizeOnDisk: Int64? = nil,
        isDirectory: Bool = false,
        consequence: String? = nil,
        isInSyncedFolder: Bool = false
    ) {
        self.id = id
        self.url = url
        self.category = category
        self.reason = reason
        self.confidence = confidence
        self.sizeOnDisk = sizeOnDisk
        self.isDirectory = isDirectory
        self.consequence = consequence
        self.isInSyncedFolder = isInSyncedFolder
    }

    public var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    /// Seleção inicial: apenas o que é confirmado e seguro.
    ///
    /// Duplicados, arquivos grandes e downloads antigos nunca vêm marcados,
    /// por mais convincentes que os números pareçam (PRD §7).
    public var isPreselectedByDefault: Bool {
        confidence == .certain && !category.requiresReinforcedConfirmation
    }
}

/// Agregação de candidatos por categoria, pronta para exibição.
public struct CleanupCategoryGroup: Identifiable, Hashable, Codable, Sendable {
    public var category: CleanupCategory
    public var candidates: [CleanupCandidate]

    public var id: String { category.rawValue }

    /// Soma apenas de itens com tamanho conhecido.
    ///
    /// A distinção importa: o PRD (§7) exige que a estimativa não "contabilize
    /// arquivos inacessíveis". Somar `0` para um item que não conseguimos medir
    /// inflaria a confiança da estimativa sem qualquer ganho de precisão, então
    /// esses itens são excluídos do total e sinalizados por
    /// `hasUnmeasuredItems`.
    public var measurableSize: Int64 {
        candidates.reduce(into: Int64(0)) { partial, item in
            if let size = item.sizeOnDisk { partial += size }
        }
    }

    public var hasUnmeasuredItems: Bool {
        candidates.contains { $0.sizeOnDisk == nil }
    }
}
