import Foundation

/// De onde um aplicativo foi encontrado.
public enum ApplicationLocation: Hashable, Codable, Sendable, CaseIterable {
    case systemApplications
    case userApplications
    case additional

    public var title: String {
        switch self {
        case .systemApplications: return "/Applications"
        case .userApplications: return "~/Applications"
        case .additional: return "Pasta adicional"
        }
    }
}

/// Um aplicativo instalado, como o macOS o enxerga.
public struct ApplicationEntry: Identifiable, Hashable, Codable, Sendable {

    public var id: String { bundleIdentifier ?? url.path }

    public let url: URL
    public let name: String
    public let bundleIdentifier: String?
    public let shortVersion: String?
    public let buildVersion: String?
    public let category: String?
    public let minimumSystemVersion: String?
    public let location: ApplicationLocation
    /// Tamanho total do bundle, quando mensurável.
    public let sizeOnDisk: Int64?
    public let modificationDate: Date?
    /// Verdadeiro quando o app está em pasta sincronizada (iCloud Drive, etc.).
    public let isInSyncedFolder: Bool
    /// Categoria de sistema (Finder, Safari, Utilitários) segundo o macOS.
    public let isAppleProvided: Bool

    public init(
        url: URL,
        name: String,
        bundleIdentifier: String?,
        shortVersion: String?,
        buildVersion: String?,
        category: String?,
        minimumSystemVersion: String?,
        location: ApplicationLocation,
        sizeOnDisk: Int64?,
        modificationDate: Date?,
        isInSyncedFolder: Bool = false,
        isAppleProvided: Bool = false
    ) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.category = category
        self.minimumSystemVersion = minimumSystemVersion
        self.location = location
        self.sizeOnDisk = sizeOnDisk
        self.modificationDate = modificationDate
        self.isInSyncedFolder = isInSyncedFolder
        self.isAppleProvided = isAppleProvided
    }

    public var versionSummary: String {
        switch (shortVersion, buildVersion) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "Versão desconhecida"
        }
    }
}

/// Um arquivo associado a um aplicativo, encontrado durante a desinstalação.
public struct LeftoverArtifact: Identifiable, Hashable, Codable, Sendable {

    public var id: String { url.path }

    public enum Association: String, Codable, Sendable, CaseIterable {
        /// Nome contém exatamente o identificador do bundle.
        case bundleIdentifierMatch
        /// Nome começa com o identificador do bundle.
        case prefixMatch
        /// Está em local canônico associado ao app, mas sem o identificador no nome.
        case locationMatch
        case unknown

        public var title: String {
            switch self {
            case .bundleIdentifierMatch: return "Identificador exato"
            case .prefixMatch: return "Prefixo do identificador"
            case .locationMatch: return "Localização conhecida"
            case .unknown: return "Associação incerta"
            }
        }

        public var confidence: Confidence {
            switch self {
            case .bundleIdentifierMatch: return .certain
            case .prefixMatch: return .likely
            case .locationMatch: return .likely
            case .unknown: return .uncertain
            }
        }
    }

    public let url: URL
    public let association: Association
    public let sizeOnDisk: Int64?
    public let isDirectory: Bool
    /// Aviso exibido ao usuário — tipicamente sobre dados que o app não
    /// consegue classificar sozinhos, como documentos salvos pelo usuário.
    public let warning: String?

    public init(
        url: URL,
        association: Association,
        sizeOnDisk: Int64?,
        isDirectory: Bool,
        warning: String? = nil
    ) {
        self.url = url
        self.association = association
        self.sizeOnDisk = sizeOnDisk
        self.isDirectory = isDirectory
        self.warning = warning
    }
}
