import Foundation

/// Motivo pelo qual um aplicativo não pode ser desinstalado.
public enum AppUninstallError: Error, Equatable, Sendable {
    /// O bundle não é um item *diretamente* dentro de `/Applications` ou
    /// `~/Applications` (inclui a própria pasta e subpastas).
    case notDirectlyInApplicationsFolder
    /// O bundle é um link simbólico. Seguir o link removeria outra coisa.
    case symlinkedBundle
    /// Não é um `.app` válido: falta `Contents/Info.plist` ou identificador.
    case invalidBundle
    /// Aplicativo da Apple ou do sistema.
    case appleApplication
    /// O próprio MacCare.
    case ownApplication
    /// O aplicativo está aberto.
    case applicationIsRunning

    public var explanation: String {
        switch self {
        case .notDirectlyInApplicationsFolder:
            return "Só aplicativos instalados diretamente em /Applications ou ~/Applications podem ser desinstalados pelo MacCare."
        case .symlinkedBundle:
            return "O aplicativo é um atalho (link simbólico). O MacCare não segue atalhos ao desinstalar."
        case .invalidBundle:
            return "O item não é um pacote de aplicativo válido (sem Info.plist ou sem identificador)."
        case .appleApplication:
            return "Aplicativos da Apple e do sistema não podem ser desinstalados pelo MacCare."
        case .ownApplication:
            return "O MacCare não desinstala a si mesmo."
        case .applicationIsRunning:
            return "O aplicativo está aberto. Feche-o antes de desinstalar."
        }
    }
}

extension AppUninstallError: LocalizedError {
    public var errorDescription: String? { explanation }
}

/// Autorização dedicada para desinstalar **um** aplicativo.
///
/// ## Por que não é o `PathGuard`
///
/// Para a limpeza geral, `/Applications` continua protegido — nenhuma regra
/// de escopo deveria permitir apagar coisas lá dentro. A desinstalação é um
/// caso diferente: o usuário escolheu UM aplicativo. Esta autorização permite
/// exatamente:
///
/// - o bundle `.app` escolhido (canonicalizado, item direto de
///   `/Applications` ou `~/Applications`), e
/// - os residuais em `~/Library` cujo nome é o identificador do bundle, nas
///   localizações de `leftoverLocations(bundleIdentifier:home:fs:)`.
///
/// Qualquer outro caminho é recusado — inclusive filhos desses itens: a
/// comparação é por igualdade, não por prefixo.
///
/// ## Garantias
///
/// - Só Lixeira: `permitsPermanentDeletion` é `false`, então o
///   `SafeFileRemover` rejeita um plano de exclusão definitiva.
/// - `ConfirmedSelection` continua obrigatória (é o `SafeFileRemover` que a
///   exige, não esta autorização).
/// - Revalidação na execução: `evaluate` confere de novo que o bundle não
///   virou link, que o identificador é o mesmo e que o app não está aberto.
public struct AppUninstallAuthorization: RemovalGuard, Sendable {

    /// Localização canônica do bundle autorizado.
    public let bundleURL: URL
    public let bundleIdentifier: String
    /// Localizações canônicas exatas dos residuais autorizados (existentes ou
    /// não no momento da criação).
    public let leftoverURLs: [URL]

    public var permitsPermanentDeletion: Bool { false }

    private let fs: any FileSystem
    private let bundleIdentifierReader: @Sendable (URL) -> String?
    private let isRunning: @Sendable (String) -> Bool

    /// - Parameters:
    ///   - bundle: o `.app` escolhido pelo usuário.
    ///   - applicationFolders: pastas onde o bundle pode estar (padrão:
    ///     `/Applications` e `~/Applications`).
    ///   - ownBundle / ownBundleIdentifier: o MacCare, que nunca se desinstala.
    ///   - bundleIdentifierReader: lê o `CFBundleIdentifier` do bundle.
    ///   - isRunning: informa se há processo com aquele identificador aberto.
    /// - Throws: `AppUninstallError` quando o bundle não pode ser desinstalado.
    public init(
        bundle: URL,
        applicationFolders: [URL] = PathGuard.applicationRoots,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        ownBundle: URL? = Bundle.main.bundleURL,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fs: any FileSystem = LiveFileSystem(),
        bundleIdentifierReader: @escaping @Sendable (URL) -> String? = AppUninstallAuthorization.readBundleIdentifier,
        isRunning: @escaping @Sendable (String) -> Bool
    ) throws {
        guard bundle.isFileURL, bundle.path.hasPrefix("/"), !PathGuard.hasTraversal(bundle) else {
            throw AppUninstallError.notDirectlyInApplicationsFolder
        }
        // O item escolhido em si não pode ser link: `canonicalLocation` não
        // segue o último componente, então checamos o próprio item.
        guard !fs.isSymbolicLink(at: bundle) else { throw AppUninstallError.symlinkedBundle }
        guard let canonical = PathGuard.canonicalLocation(of: bundle) else {
            throw AppUninstallError.notDirectlyInApplicationsFolder
        }
        if let ownBundle, let ownCanonical = PathGuard.canonicalDirectory(of: ownBundle),
           PathGuard.isSameOrDescendant(canonical, of: ownCanonical, caseInsensitive: true) {
            throw AppUninstallError.ownApplication
        }
        // Pai canônico tem de ser exatamente uma das pastas de aplicativos.
        // Isso recusa a própria pasta, subpastas e — porque o pai é resolvido
        // com realpath — pastas que só "parecem" /Applications via link.
        let parent = canonical.deletingLastPathComponent()
        let folders = applicationFolders.compactMap { PathGuard.canonicalDirectory(of: $0) }
        guard folders.contains(where: { PathGuard.isEqual(parent, $0, caseInsensitive: true) }) else {
            throw AppUninstallError.notDirectlyInApplicationsFolder
        }
        guard canonical.pathExtension.lowercased() == "app",
              fs.isDirectory(at: canonical),
              fs.itemExists(at: canonical.appendingPathComponent("Contents/Info.plist")),
              let identifier = bundleIdentifierReader(canonical),
              !identifier.isEmpty
        else {
            throw AppUninstallError.invalidBundle
        }
        if identifier.lowercased().hasPrefix("com.apple.") {
            throw AppUninstallError.appleApplication
        }
        if let ownBundleIdentifier, identifier.caseInsensitiveCompare(ownBundleIdentifier) == .orderedSame {
            throw AppUninstallError.ownApplication
        }
        if isRunning(identifier) { throw AppUninstallError.applicationIsRunning }

        self.bundleURL = canonical
        self.bundleIdentifier = identifier
        self.leftoverURLs = Self.leftoverLocations(bundleIdentifier: identifier, home: home, fs: fs)
            .compactMap { PathGuard.canonicalLocation(of: $0) }
        self.fs = fs
        self.bundleIdentifierReader = bundleIdentifierReader
        self.isRunning = isRunning
    }

    /// Avalia um caminho no momento da execução.
    public func evaluate(_ url: URL) -> PathVerdict {
        guard url.isFileURL, url.path.hasPrefix("/") else { return .denied(.relativePath) }
        guard !PathGuard.hasTraversal(url) else { return .denied(.pathTraversal) }
        guard let resolved = PathGuard.canonicalLocation(of: url) else { return .denied(.unresolvable) }

        if PathGuard.isEqual(resolved, bundleURL, caseInsensitive: true) {
            // Revalidação: o bundle pode ter mudado desde a autorização.
            guard !fs.isSymbolicLink(at: resolved) else { return .denied(.symlinkEscapesScope) }
            guard fs.isDirectory(at: resolved),
                  bundleIdentifierReader(resolved) == bundleIdentifier
            else { return .denied(.notAnUninstallableApplication) }
            guard !isRunning(bundleIdentifier) else { return .denied(.applicationIsRunning) }
            return .allowed(resolved: resolved, isSymlink: false)
        }

        if leftoverURLs.contains(where: { PathGuard.isEqual(resolved, $0, caseInsensitive: true) }) {
            // Apagar dados de um app aberto corrompe o estado dele.
            guard !isRunning(bundleIdentifier) else { return .denied(.applicationIsRunning) }
            // Um residual que é link: só o link sai (localização do próprio link).
            return .allowed(resolved: resolved, isSymlink: fs.isSymbolicLink(at: resolved))
        }

        return .denied(.notAnUninstallableApplication)
    }

    /// Onde residuais de um app podem estar, todos em `~/Library` e todos
    /// nomeados pelo identificador do bundle. Nada fora da pasta do usuário.
    ///
    /// `Group Containers` usa `<TEAMID>.<id>` (TEAMID = 10 caracteres
    /// alfanuméricos maiúsculos) ou `<id>`; é o único caso listado do disco.
    public static func leftoverLocations(bundleIdentifier id: String, home: URL, fs: any FileSystem) -> [URL] {
        // Identificador com "/" ou ".." nunca vira nome de caminho.
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else { return [] }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        func at(_ folder: String, _ name: String) -> URL {
            library.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name)
        }
        var locations = [
            at("Application Support", id),
            at("Caches", id),
            at("Preferences", "\(id).plist"),
            at("Containers", id),
            at("Group Containers", id),
            at("Saved Application State", "\(id).savedState"),
            at("Logs", id),
            at("HTTPStorages", id),
            at("HTTPStorages", "\(id).binarycookies"),
            at("WebKit", id),
            at("LaunchAgents", "\(id).plist")
        ]
        let groups = library.appendingPathComponent("Group Containers", isDirectory: true)
        if let entries = try? fs.contents(of: groups) {
            for entry in entries where isTeamPrefixedGroup(entry.lastPathComponent, bundleIdentifier: id) {
                locations.append(groups.appendingPathComponent(entry.lastPathComponent))
            }
        }
        return locations
    }

    static func isTeamPrefixedGroup(_ name: String, bundleIdentifier id: String) -> Bool {
        let suffix = "." + id
        guard name.count == 10 + suffix.count, name.hasSuffix(suffix) else { return false }
        return name.prefix(10).allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    public static let readBundleIdentifier: @Sendable (URL) -> String? = { url in
        ApplicationCatalog.readInfoPlist(at: url)?["CFBundleIdentifier"] as? String
    }
}
