import Darwin
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
    case pathTraversal
    case applicationIsRunning
    case notAnUninstallableApplication

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
        case .pathTraversal:
            return "O caminho contém \"..\". Caminhos com travessia de diretório nunca são aceitos."
        case .applicationIsRunning:
            return "O aplicativo está aberto. Feche-o antes de desinstalar."
        case .notAnUninstallableApplication:
            return "Este item não faz parte da desinstalação autorizada deste aplicativo."
        }
    }
}

/// Resultado da avaliação de um caminho.
public enum PathVerdict: Hashable, Sendable {
    /// `resolved` é a localização canônica do PRÓPRIO item. Quando o item é um
    /// link simbólico, `resolved` aponta para o link, nunca para o destino, e
    /// `isSymlink` é `true`: a remoção afeta só o link.
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
/// Qualquer coisa capaz de decidir se um caminho pode ser removido.
///
/// `SafeFileRemover` só conhece este protocolo. Há duas implementações:
/// `PathGuard` (limpeza geral, por escopo) e `AppUninstallAuthorization`
/// (desinstalação de UM aplicativo, por lista exata de caminhos).
public protocol RemovalGuard: Sendable {
    func evaluate(_ url: URL) -> PathVerdict
    /// `false` impede `.permanentlyDelete` mesmo com autorização no plano.
    var permitsPermanentDeletion: Bool { get }
}

public struct PathGuard: RemovalGuard, Sendable {

    public var permitsPermanentDeletion: Bool { true }

    /// Raízes (já resolvidas) que o usuário autorizou para leitura/limpeza.
    public let allowedRoots: [URL]
    /// As raízes como foram escritas (padronizadas), usadas só para escolher
    /// a mensagem de recusa — nunca para autorizar.
    private let declaredRoots: [URL]
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
        // Raízes com ".." ou que não resolvem são descartadas: uma raiz
        // inválida nunca vira "autoriza tudo", só deixa de autorizar.
        self.declaredRoots = allowedRoots
            .filter { $0.isFileURL && !PathGuard.hasTraversal($0) }
            .map { $0.standardizedFileURL }
        self.allowedRoots = allowedRoots
            .filter { $0.isFileURL }
            .compactMap { PathGuard.canonicalDirectory(of: $0) }
        // Caminhos protegidos entram nas duas formas (como escritos e
        // canônicos): `/var` e `/private/var` são o mesmo lugar.
        self.protectedPaths = protectedPaths
            .filter { $0.isFileURL }
            .flatMap { url -> [URL] in
                let canonical = PathGuard.canonicalDirectory(of: url)
                return [url.standardizedFileURL] + (canonical.map { [$0] } ?? [])
            }
        self.ownBundle = ownBundle.flatMap { PathGuard.canonicalDirectory(of: $0) }
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
        guard !PathGuard.hasTraversal(url) else { return .denied(.pathTraversal) }

        guard let resolved = PathGuard.canonicalLocation(of: url) else { return .denied(.unresolvable) }
        let isSymlink = PathGuard.isSymbolicLink(resolved)

        // Ordem das recusas: da mais específica para a mais genérica. Todas
        // são recusas — a ordem só decide QUAL motivo o usuário vê.

        if let ownBundle, isSameOrDescendant(resolved, of: ownBundle, caseInsensitive: caseInsensitive) {
            return .denied(.ownApplicationBundle)
        }

        // `/Applications` e `~/Applications` como um todo nunca são removíveis.
        for root in PathGuard.applicationRoots {
            if let canonicalRoot = PathGuard.canonicalDirectory(of: root),
               PathGuard.isEqual(resolved, canonicalRoot, caseInsensitive: caseInsensitive) {
                return .denied(.applicationRootDirectory)
            }
        }

        // Raízes de volume, diretórios de primeiro nível (/, /Users) e as
        // raízes de sistema que no macOS vivem um nível abaixo de /private
        // (/private/tmp, /private/var, /private/etc). Sem a segunda regra,
        // `/tmp` canonicalizado (`/private/tmp`, 3 componentes) escaparia da
        // regra de "primeiro nível".
        guard resolved.pathComponents.count > 2 else { return .denied(.volumeOrTopLevelDirectory) }
        for root in PathGuard.nonRemovableRoots
        where PathGuard.isEqual(resolved, root, caseInsensitive: caseInsensitive) {
            return .denied(.volumeOrTopLevelDirectory)
        }

        if let home = PathGuard.homeDirectory.flatMap({ PathGuard.canonicalDirectory(of: $0) }),
           PathGuard.isEqual(resolved, home, caseInsensitive: caseInsensitive) {
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
            // Distingue "usuário nunca autorizou esta área" de "um link
            // simbólico no caminho nos tirou do escopo" — a segunda é um sinal
            // de risco que vale mostrar.
            let written = url.standardizedFileURL
            let writtenInScope = (allowedRoots + declaredRoots).contains { root in
                isStrictDescendant(written, of: root, caseInsensitive: caseInsensitive)
            }
            return .denied(writtenInScope ? .symlinkEscapesScope : .outsideAllowedScope)
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

    /// Localização canônica de um caminho, no estilo de `realpath(3)`.
    ///
    /// Regras, aplicadas de forma idêntica a raízes autorizadas, caminhos
    /// protegidos e candidatos:
    ///
    /// 1. Caminho relativo ou com componente `..` → `nil` (recusado).
    /// 2. O **diretório pai** é resolvido com `realpath` no ancestral existente
    ///    mais profundo; os componentes que ainda não existem são anexados
    ///    literalmente. Assim `/private/tmp` e `/tmp/arquivo-inexistente`
    ///    caem no mesmo prefixo (`/private/tmp/...`), coisa que
    ///    `resolvingSymlinksInPath()` não garante (ele só remove o `/private`
    ///    quando o caminho existe).
    /// 3. Para **candidatos** (`followFinalSymlink == false`, o padrão) o
    ///    último componente nunca é seguido: se ele for um link simbólico, a
    ///    localização devolvida é a do próprio link. Isso é o que garante que
    ///    remover um link nunca alcance o destino.
    /// 4. Para **diretórios de referência** — raízes autorizadas, caminhos
    ///    protegidos, pastas de aplicativos, pasta pessoal —
    ///    `followFinalSymlink == true`: `/tmp` como raiz significa "dentro de
    ///    `/private/tmp`".
    public static func canonicalLocation(of url: URL, followFinalSymlink: Bool = false) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/"), !hasTraversal(url) else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard !components.isEmpty else { return URL(fileURLWithPath: "/") }
        if followFinalSymlink {
            return resolvingDeepestExistingAncestor(components, trailingLeaf: nil)
        }
        return resolvingDeepestExistingAncestor(Array(components.dropLast()), trailingLeaf: components.last)
    }

    /// Mesma regra que `canonicalLocation`, seguindo também o último
    /// componente. Usada para tudo que é "pasta de referência".
    public static func canonicalDirectory(of url: URL) -> URL? {
        canonicalLocation(of: url, followFinalSymlink: true)
    }

    private static func resolvingDeepestExistingAncestor(_ parentComponents: [String], trailingLeaf leaf: String?) -> URL {
        var parent = "/"
        var existingCount = parentComponents.count
        while existingCount >= 0 {
            let prefix = "/" + parentComponents.prefix(existingCount).joined(separator: "/")
            if let real = realPath(prefix) {
                parent = real
                break
            }
            existingCount -= 1
        }
        let remaining = parentComponents.dropFirst(max(existingCount, 0))
        var result = URL(fileURLWithPath: parent, isDirectory: true)
        for component in remaining {
            result.appendPathComponent(component)
        }
        if let leaf { result.appendPathComponent(leaf) }
        return URL(fileURLWithPath: result.path)
    }

    /// Compatibilidade: mesma coisa que `canonicalLocation(of:)`, devolvendo
    /// o caminho padronizado quando ele não pode ser canonicalizado.
    public static func resolve(_ url: URL) -> URL {
        canonicalLocation(of: url) ?? url.standardizedFileURL
    }

    /// `true` quando algum componente do caminho é `..`.
    public static func hasTraversal(_ url: URL) -> Bool {
        url.path.split(separator: "/").contains("..")
    }

    /// `lstat`: o item em si é um link simbólico (sem segui-lo).
    public static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func realPath(_ path: String) -> String? {
        guard let buffer = Darwin.realpath(path, nil) else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
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

    /// Diretórios que nunca podem ser removidos *eles mesmos*, mesmo quando
    /// o conteúdo pode (ex.: arquivos em `/private/tmp`). Comparados com o
    /// caminho canônico, nas duas grafias.
    public static let nonRemovableRoots: [URL] = [
        "/private", "/private/tmp", "/private/var", "/private/etc",
        "/tmp", "/var", "/etc", "/Users", "/Volumes", "/Library", "/System"
    ].map { URL(fileURLWithPath: $0) }

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
