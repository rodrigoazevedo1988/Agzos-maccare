import Foundation

/// Um arquivo grande ou antigo encontrado na varredura.
public struct LargeFileEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { url.path }

    public let url: URL
    public let sizeOnDisk: Int64
    public let modificationDate: Date?
    public let isDirectory: Bool
    public let isInSyncedFolder: Bool

    public init(
        url: URL,
        sizeOnDisk: Int64,
        modificationDate: Date?,
        isDirectory: Bool,
        isInSyncedFolder: Bool = false
    ) {
        self.url = url
        self.sizeOnDisk = sizeOnDisk
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
        self.isInSyncedFolder = isInSyncedFolder
    }

    public var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}

/// Um conjunto de arquivos com conteúdo idêntico, confirmado por hash.
public struct DuplicateGroup: Identifiable, Hashable, Codable, Sendable {

    public var id: String { digest }

    /// SHA-256 hexadecimal do conteúdo comum ao grupo.
    public let digest: String
    public let sizeOnDisk: Int64
    public let fileCount: Int
    public let newest: Date?
    public let oldest: Date?
    /// `true` quando algum item do grupo está em pasta sincronizada.
    public let isInSyncedFolder: Bool
    /// `true` quando o grupo contém caminhos que são hard links do mesmo inode.
    /// Nesse caso, remover mais de um item pode apagar o arquivo inteiro.
    public let containsHardLinks: Bool

    public let items: [LargeFileEntry]

    public init(
        digest: String,
        sizeOnDisk: Int64,
        items: [LargeFileEntry],
        newest: Date? = nil,
        oldest: Date? = nil,
        isInSyncedFolder: Bool = false,
        containsHardLinks: Bool = false
    ) {
        self.digest = digest
        self.sizeOnDisk = sizeOnDisk
        self.items = items
        self.fileCount = items.count
        self.newest = newest
        self.oldest = oldest
        self.isInSyncedFolder = isInSyncedFolder
        self.containsHardLinks = containsHardLinks
    }

    /// Espaço que seria recuperado removendo todos, menos uma cópia.
    /// Preserva uma referência — o PRD §11 exige "preservar pelo menos uma
    /// cópia de cada grupo".
    public var reclaimableSize: Int64 { sizeOnDisk * Int64(max(0, fileCount - 1)) }

    /// Item sugerido para preservação: o mais antigo do grupo.
    ///
    /// A sugestão nunca é aplicada sozinha. O PRD §11 proíbe apagar
    /// automaticamente "a cópia considerada mais antiga" — a regra aqui
    /// existe só para sugerir ao usuário qual cópia costuma ser a mais
    /// segura.
    public var keepSuggestion: LargeFileEntry? {
        items.min { lhs, rhs in
            (lhs.modificationDate ?? .distantFuture) < (rhs.modificationDate ?? .distantFuture)
        }
    }
}

/// Um nó da árvore hierárquica de armazenamento.
public struct StorageNode: Identifiable, Hashable, Codable, Sendable {
    public var id: String { url.path }

    public let url: URL
    public let name: String
    public let sizeOnDisk: Int64
    /// `true` quando o tamanho é uma estimativa, porque parte da árvore não
    /// pôde ser lida. A interface sinaliza isso explicitamente.
    public let isPartial: Bool
    public let children: [StorageNode]

    public init(url: URL, name: String, sizeOnDisk: Int64, isPartial: Bool, children: [StorageNode]) {
        self.url = url
        self.name = name
        self.sizeOnDisk = sizeOnDisk
        self.isPartial = isPartial
        self.children = children
    }

    public static func leaf(url: URL, sizeOnDisk: Int64, isPartial: Bool = false) -> StorageNode {
        StorageNode(url: url, name: url.lastPathComponent, sizeOnDisk: sizeOnDisk, isPartial: isPartial, children: [])
    }
}

/// Item de inicialização identificado no sistema.
public struct StartupItem: Identifiable, Hashable, Codable, Sendable {

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case launchAgent
        case launchDaemon
        case loginItem
        case backgroundItem

        public var title: String {
            switch self {
            case .launchAgent: return "Launch Agent"
            case .launchDaemon: return "Launch Daemon"
            case .loginItem: return "Item de login"
            case .backgroundItem: return "Segundo plano"
            }
        }
    }

    public enum Source: String, Codable, Sendable {
        case userLibrary
        case systemLibrary
        case serviceManagement

        public var title: String {
            switch self {
            case .userLibrary: return "Biblioteca do usuário"
            case .systemLibrary: return "Biblioteca do sistema"
            case .serviceManagement: return "Gerenciamento de login"
            }
        }
    }

    public var id: String { url.path }

    public let label: String
    /// `true` quando o item pertence ao macOS e não deve ser tocado.
    public let isSystemProvided: Bool
    public let kind: Kind
    public let source: Source
    public let url: URL
    public let bundleIdentifier: String?
    /// Estado habilitado/desabilitado, quando consultável por API pública.
    /// `nil` significa "o macOS não expõe esse estado" — não "está desabilitado".
    public let isEnabled: Bool?
    public let summary: String?
    /// `true` quando o item está de fato carregado no sistema neste momento.
    public let isCurrentlyRunning: Bool

    public init(
        label: String,
        isSystemProvided: Bool,
        kind: Kind,
        source: Source,
        url: URL,
        bundleIdentifier: String? = nil,
        isEnabled: Bool? = nil,
        summary: String? = nil,
        isCurrentlyRunning: Bool = false
    ) {
        self.label = label
        self.isSystemProvided = isSystemProvided
        self.kind = kind
        self.source = source
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.isEnabled = isEnabled
        self.summary = summary
        self.isCurrentlyRunning = isCurrentlyRunning
    }

    /// O macOS permite alterar o estado apenas do próprio aplicativo do MacCare.
    /// Qualquer outro item exige ação manual nas Configurações do Sistema.
    public var canToggleInApp: Bool { false }
}
