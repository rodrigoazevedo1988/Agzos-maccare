import Foundation

/// Motivo pelo qual um caminho foi recusado pelo motor de segurança.
///
/// Cada caso é observável: o app mostra o motivo na interface em vez de
/// esconder a falha. Um item recusado não é um bug, é uma proteção funcionando.
public enum PathGuardCode: String, Codable, Sendable, CaseIterable {
    case emptyPath
    case relativePath
    case notAFileURL
    case volumeOrTopLevelDirectory
    case homeDirectoryItself
    case protectedSystemPath
    case applicationRootDirectory
    case ownApplicationBundle
    case symlinkEscapesScope
    case outsideAllowedScope
    case unresolvable

    public var explanation: String {
        switch self {
        case .emptyPath:
            return "Caminho vazio."
        case .relativePath:
            return "O caminho não é absoluto."
        case .notAFileURL:
            return "O item não é um arquivo local."
        case .volumeOrTopLevelDirectory:
            return "Diretórios de primeiro nível e raízes de volume nunca são removidos."
        case .homeDirectoryItself:
            return "A pasta pessoal do usuário não pode ser removida."
        case .protectedSystemPath:
            return "Este caminho faz parte do sistema operacional ou é essencial ao macOS."
        case .applicationRootDirectory:
            return "A pasta /Applications não é removível. Desinstalar aplicativo é uma operação separada e item a item."
        case .ownApplicationBundle:
            return "O MacCare não pode remover o próprio aplicativo em execução."
        case .symlinkEscapesScope:
            return "O link simbólico aponta para fora da área autorizada. Seguiria para um destino não escopado."
        case .outsideAllowedScope:
            return "O caminho está fora das pastas que você autorizou para análise."
        case .unresolvable:
            return "Não foi possível resolver o caminho no sistema de arquivos."
        }
    }
}

/// Resultado da avaliação de um caminho.
public enum PathVerdict: Hashable, Sendable {
    case allowed(resolved: URL, isSymlink: Bool)
    case denied(PathGuardCode)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var deniedCode: PathGuardCode? {
        if case .denied(let code) = self { return code }
        return nil
    }
}

/// Guardião de caminhos: a única porta de entrada para qualquer operação
/// destrutiva do aplicativo.
///
/// ## Por que existe como tipo separado
///
/// O PRD (§4, §8) exige que "toda operação potencialmente destrutiva deverá
/// passar por serviços próprios, com validações". Concentrar as regras em um
/// único tipo auditável — em vez de espalhadas por dez view models — significa
/// que a lista de proibições cabe em uma tela e que a suíte de testes de
/// segurança (§25) consegue exercitar *todas* as regras sem tocar o disco real.
///
/// ## Semântica de escopo
///
/// O guardião trabalha com dois conjuntos de caminhos: as raízes que o usuário
/// autorizou para análise e os caminhos sempre protegidos. Um caminho só é
/// liberado se, **após resolver links simbólicos**, ele estiver estritamente
/// dentro de uma raiz autorizada *e* fora de qualquer caminho protegido.
///
/// Resolver antes de comparar é o que impede o ataque clássico: um link
/// simbólico colocado dentro de uma pasta autorizada apontando para `/System`.
/// Symlinks legítimos do macOS (`/tmp` → `/private/tmp`, `~` → `/Users/x`)
/// continuam funcionando porque as raízes autorizadas são normalizadas pelo
/// mesmo procedimento.
public struct PathGuard: Sendable {

    /// Raízes (já resolvidas) que o usuário autorizou para leitura/limpeza.
    public let allowedRoots: [URL]
    /// Caminhos (já resolvidos) que são proibidos em qualquer cenário.
    public let protectedPaths: [URL]
    /// Bundle do próprio aplicativo, protegido de autorremoção.
    public let ownBundle: URL?
    /// Resolve e compara case-insensitive em volumes que não distinguem maiúsculas.
    public let caseInsensitive: Bool

    public init(
        allowedRoots: [URL],
        protectedPaths: [URL] = PathGuard.defaultProtectedPaths,
        ownBundle: URL? = nil,
        caseInsensitive: Bool = true
    ) {
        // Raízes são resolvidas na inicialização. `filter` remove entradas que
        // não são URLs de arquivo (ex.: a string "~/Cache" montada errada).
        self.allowedRoots = allowedRoots
            .filter { $0.isFileURL }
            .map { PathGuard.resolve($0) }
        self.protectedPaths = protectedPaths
            .filter { $0.isFileURL }
            .map { PathGuard.resolve($0) }
        self.ownBundle = ownBundle.map { PathGuard.resolve($0) }
        self.caseInsensitive = caseInsensitive
    }

    /// Guardião usado em modo de simulação e nos testes: não autoriza nada.
    ///
    /// Falhar fechado é intencional. Um guard constructed sem escopo nunca deve
    /// permitir uma remoção.
    public static let denyAll = PathGuard(allowedRoots: [])

    // MARK: - Avaliação

    /// Avalia um caminho e decide se ele pode participar de uma operação.
    ///
    /// Esta função **não toca no disco**: é pura, exceto pela resolução de
    /// symlinks feita pelo sistema. O toque no disco (exclusão de fato) é
    /// responsabilidade de `SafeFileRemover`, sempre depois deste retorno.
    public func evaluate(_ url: URL) -> PathVerdict {
        guard !url.path.isEmpty else { return .denied(.emptyPath) }
        guard url.isFileURL else { return .denied(.notAFileURL) }
        guard url.path.hasPrefix("/") else { return .denied(.relativePath) }

        let standardized = url.standardizedFileURL
        let resolved = PathGuard.resolve(standardized)
        let isSymlink = resolved.path != standardized.path

        // Ordem das recusas: da mais específica para a mais genérica. Todas
        // são recusas — a ordem só decide QUAL motivo o usuário vê. Antes, o
        // próprio bundle e `/Applications` caíam nas regras genéricas
        // (primeiro nível / caminho protegido) e os motivos específicos
        // `.ownApplicationBundle` e `.applicationRootDirectory` nunca apareciam.

        if let ownBundle, isSameOrDescendant(resolved, of: ownBundle, caseInsensitive: caseInsensitive) {
            return .denied(.ownApplicationBundle)
        }

        // `/Applications` e `~/Applications` como um todo nunca são removíveis.
        for root in PathGuard.applicationRoots {
            if PathGuard.isEqual(resolved, root, caseInsensitive: caseInsensitive) {
                return .denied(.applicationRootDirectory)
            }
        }

        // Raízes de volume e diretórios de primeiro nível (/, /tmp, /Users).
        // `pathComponents` de "/" é ["/"] e de "/tmp" é ["/", "tmp"].
        guard resolved.pathComponents.count > 2 else { return .denied(.volumeOrTopLevelDirectory) }

        if let home = PathGuard.homeDirectory, PathGuard.isEqual(resolved, home, caseInsensitive: caseInsensitive) {
            return .denied(.homeDirectoryItself)
        }

        for protected in protectedPaths
        where isSameOrDescendant(resolved, of: protected, caseInsensitive: caseInsensitive) {
            return .denied(.protectedSystemPath)
        }

        guard !allowedRoots.isEmpty else { return .denied(.outsideAllowedScope) }

        let inScope = allowedRoots.contains { root in
            isStrictDescendant(resolved, of: root, caseInsensitive: caseInsensitive)
        }

        guard inScope else {
            // Distingue "usuário nunca autorizou esta área" de "o link simbólico
            // nos tirou do escopo" — as duas coisas exigem ações diferentes do
            // usuário, e a segunda é um sinal de risco que vale mostrar.
            let standardInScope = allowedRoots.contains { root in
                isStrictDescendant(standardized, of: root, caseInsensitive: caseInsensitive)
            }
            return .denied(standardInScope ? .symlinkEscapesScope : .outsideAllowedScope)
        }

        return .allowed(resolved: resolved, isSymlink: isSymlink)
    }

    // MARK: - Utilitários de caminho

    /// `true` quando `url` é igual a `base` ou está dentro dele.
    public func isSameOrDescendant(_ url: URL, of base: URL, caseInsensitive: Bool? = nil) -> Bool {
        PathGuard.isSameOrDescendant(url, of: base, caseInsensitive: caseInsensitive ?? self.caseInsensitive)
    }

    /// `true` quando `url` está estritamente dentro de `base` (não é igual).
    public func isStrictDescendant(_ url: URL, of base: URL, caseInsensitive: Bool? = nil) -> Bool {
        PathGuard.isStrictDescendant(url, of: base, caseInsensitive: caseInsensitive ?? self.caseInsensitive)
    }

    /// Normaliza e resolve links simbólicos de um caminho.
    public static func resolve(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isSameOrDescendant(_ url: URL, of base: URL, caseInsensitive: Bool) -> Bool {
        let (child, parent) = normalizedPair(url, base, caseInsensitive: caseInsensitive)
        if child == parent { return true }
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(prefix)
    }

    static func isStrictDescendant(_ url: URL, of base: URL, caseInsensitive: Bool) -> Bool {
        let (child, parent) = normalizedPair(url, base, caseInsensitive: caseInsensitive)
        if child == parent { return false }
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(prefix)
    }

    private static func normalizedPair(_ a: URL, _ b: URL, caseInsensitive: Bool) -> (String, String) {
        let left = a.path
        let right = b.path
        return caseInsensitive ? (left.lowercased(), right.lowercased()) : (left, right)
    }

    static func isEqual(_ a: URL, _ b: URL, caseInsensitive: Bool) -> Bool {
        let (left, right) = normalizedPair(a, b, caseInsensitive: caseInsensitive)
        return left == right
    }

    // MARK: - Caminhos protegidos do sistema

    /// Lista central de caminhos que nenhuma operação pode tocar.
    ///
    /// Não é uma lista exaustiva de caminhos protegidos por SIP — não existe
    /// API pública para enumerá-los. É a lista de **recusas explícitas** que o
    /// app aplica sempre, documentada em `docs/SAFETY.md`.
    public static var defaultProtectedPaths: [URL] {
        var paths: [String] = [
            // Núcleo do sistema
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/dev",
            "/var",
            "/private/etc",
            "/private/var",
            "/private/tmp/system",
            // Rede e montagens
            "/Network",
            "/Volumes/Preloaded",
            // Facetas de segurança do sistema
            "/Library/Keychains",
            "/Library/Security",
            "/Library/Extensions",
            "/Library/PrivateFrameworks",
            "/Library/Apple",
            // Dados de firmware
            "/Library/Preferences/com.apple.loginwindow.plist"
        ]
        paths.append(contentsOf: applicationRoots.map(\.path))
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// Raízes de onde aplicativos são descobertos. Nunca removíveis em bloco.
    public static var applicationRoots: [URL] {
        var roots = [URL(fileURLWithPath: "/Applications")]
        if let home = homeDirectory {
            roots.append(home.appendingPathComponent("Applications"))
        }
        return roots
    }

    /// Pasta pessoal do usuário, quando disponível no ambiente atual.
    public static var homeDirectory: URL? {
        FileManager.default.homeDirectoryForCurrentUser
    }
}
