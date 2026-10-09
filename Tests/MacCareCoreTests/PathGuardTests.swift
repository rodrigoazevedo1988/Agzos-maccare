import Foundation
import Testing
@testable import MacCareCore

/// ## Testes de segurança — `PathGuard`
///
/// Este é o arquivo mais importante da suíte. O PRD §25 lista como critério
/// de segurança: "nenhuma exclusão de diretórios proibidos", "tratamento de
/// links simbólicos" e "nenhuma exclusão sem confirmação". Os dois primeiros
/// são verificados aqui; o terceiro, em `SafeFileRemoverTests`.
///
/// Os caminhos usam a estrutura real de um Mac (`/Users/teste/...`) em vez de
/// temporários reais, porque o que está em teste é a *decisão*, não o disco.
@Suite("Segurança — PathGuard")
struct PathGuardTests {

    private let home = "/Users/teste"
    private let caches = "/Users/teste/Library/Caches"
    private let downloads = "/Users/teste/Downloads"

    private func guardAllowing(_ roots: [String], ownBundle: String? = nil) -> PathGuard {
        PathGuard(
            allowedRoots: roots.map { URL(fileURLWithPath: $0) },
            ownBundle: ownBundle.map { URL(fileURLWithPath: $0) }
        )
    }

    // MARK: - Autorização básica

    @Test func testPermiteCaminhoDentroDoEscopoAutorizado() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Users/teste/Library/Caches/com.app/cache.bin"))

        #expect(verdict.isAllowed, "um cache dentro de Caches deve ser permitido")
    }

    @Test func testRecusaCaminhoForaDoEscopoAutorizado() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Users/teste/Documents/contrato.pdf"))

        #expect(verdict.deniedCode == .outsideAllowedScope)
    }

    /// Falhar fechado: sem escopo, nada é autorizado.
    ///
    /// Este é o teste mais importante da suíte de segurança. Um `PathGuard`
    /// construído sem raízes é o estado em que uma refatoração ingênua poderia
    /// deixar o app — e o teste garante que esse estado **não remove nada**.
    @Test func testSemEscopoAutorizadoNaoPermiteNada() {
        let guardrail = PathGuard.denyAll
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Users/teste/Library/Caches/qualquer.bin"))

        #expect(!verdict.isAllowed)
        #expect(verdict.deniedCode == .outsideAllowedScope)
    }

    // MARK: - Caminhos protegidos

    @Test func testRecusaRaizDoSistema() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))

        #expect(verdict.deniedCode == .protectedSystemPath)
    }

    @Test func testRecusaDescendenteDeCaminhoProtegido() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/usr/local/lib/anything.dylib"))

        #expect(verdict.deniedCode == .protectedSystemPath)
    }

    @Test func testRecusaBibliotecaDoSistema() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Library/Keychains/System.keychain"))

        #expect(verdict.deniedCode == .protectedSystemPath)
    }

    @Test func testRecusaRaizDoVolume() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/"))

        #expect(verdict.deniedCode == .volumeOrTopLevelDirectory)
    }

    @Test func testRecusaDiretorioDePrimeiroNivel() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/tmp"))

        #expect(verdict.deniedCode == .volumeOrTopLevelDirectory)
    }

    @Test func testRecusaPastaAplicacoesInteira() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Applications"))

        #expect(verdict.deniedCode == .applicationRootDirectory)
    }

    @Test func testRecusaRemocaoDoProprioBundle() {
        let guardrail = guardAllowing(["/"], ownBundle: "/Applications/MacCare.app")
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Applications/MacCare.app/Contents/MacOS/MacCare"))

        #expect(verdict.deniedCode == .ownApplicationBundle)
    }

    // MARK: - Links simbólicos

    /// Cria uma pasta temporária real em `/tmp` (não em
    /// `FileManager.temporaryDirectory`, que fica em `/private/var`, caminho
    /// protegido) e apaga tudo no fim — inclusive se o teste falhar.
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("maccare-pathguard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /// Um link de verdade dentro do escopo, apontando para `/System/Library`:
    /// qualquer caminho que **atravesse** o link é resolvido para o destino e
    /// recusado como caminho de sistema.
    ///
    /// Este é o cenário de ataque clássico: o app varre `~/Library/Caches`,
    /// encontra um link, segue o link e apaga `/System/Library`.
    @Test func testRecusaSymlinkQueSaiDoEscopo() throws {
        try withTemporaryDirectory { dir in
            let scope = dir.appendingPathComponent("escopo", isDirectory: true)
            try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
            let link = scope.appendingPathComponent("atalho")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/System/Library")

            let guardrail = PathGuard(allowedRoots: [scope])
            let throughLink = link.appendingPathComponent("CoreServices")

            let verdict = guardrail.evaluate(throughLink)
            #expect(!verdict.isAllowed)
            #expect(verdict.deniedCode == .protectedSystemPath, "o destino real é /System/Library/CoreServices")
            #expect(FileManager.default.fileExists(atPath: "/System/Library/CoreServices"))
        }
    }

    /// Link dentro do escopo apontando para uma pasta comum fora do escopo:
    /// atravessá-lo é recusado como fuga de escopo (não como "fora do escopo"
    /// genérico), porque o caminho escrito parecia estar dentro.
    @Test func testRecusaCaminhoAtravesDeSymlinkParaForaDoEscopo() throws {
        try withTemporaryDirectory { dir in
            let scope = dir.appendingPathComponent("escopo", isDirectory: true)
            let outside = dir.appendingPathComponent("fora", isDirectory: true)
            try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("dados".utf8).write(to: outside.appendingPathComponent("documento.txt"))
            let link = scope.appendingPathComponent("atalho")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

            let guardrail = PathGuard(allowedRoots: [scope])
            let verdict = guardrail.evaluate(link.appendingPathComponent("documento.txt"))

            #expect(verdict.deniedCode == .symlinkEscapesScope)
        }
    }

    /// O link **em si** dentro do escopo é removível — mas o veredito aponta
    /// para a localização do link e marca `isSymlink`, nunca para o destino.
    @Test func testLinkNoEscopoResolveParaOProprioLink() throws {
        try withTemporaryDirectory { dir in
            let scope = dir.appendingPathComponent("escopo", isDirectory: true)
            try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
            let link = scope.appendingPathComponent("atalho-sistema")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/System/Library")

            let guardrail = PathGuard(allowedRoots: [scope])
            guard case .allowed(let resolved, let isSymlink) = guardrail.evaluate(link) else {
                Issue.record("o link dentro do escopo deveria ser permitido (só o link)")
                return
            }
            #expect(isSymlink)
            #expect(resolved.lastPathComponent == "atalho-sistema")
            #expect(!resolved.path.hasPrefix("/System"), "o veredito nunca pode apontar para o destino")
        }
    }

    /// Um link **para dentro** do escopo é legítimo e deve passar.
    ///
    /// `/tmp` é um symlink para `/private/tmp` no macOS. Raízes e candidatos
    /// passam pela mesma canonicalização, então qualquer combinação de grafias
    /// — inclusive para arquivos que ainda não existem — chega ao mesmo prefixo.
    @Test func testPermiteSymlinkResolvidoDentroDoEscopo() {
        let inexistente = "arquivo-\(UUID().uuidString).txt"
        for (root, candidate) in [
            ("/private/tmp", "/private/tmp/\(inexistente)"),
            ("/tmp", "/tmp/\(inexistente)"),
            ("/tmp", "/private/tmp/\(inexistente)"),
            ("/private/tmp", "/tmp/\(inexistente)"),
            ("/tmp", "/tmp/pasta-inexistente/sub/\(inexistente)")
        ] {
            let verdict = guardAllowing([root]).evaluate(URL(fileURLWithPath: candidate))
            #expect(verdict.isAllowed, "\(candidate) deveria estar dentro de \(root)")
        }
    }

    /// As raízes de sistema que vivem um nível abaixo de `/private` nunca são
    /// removíveis em si, em nenhuma das grafias.
    @Test(arguments: ["/private", "/private/tmp", "/private/var", "/private/etc", "/tmp", "/var", "/etc"])
    func testRecusaRaizesDeSistemaEmPrivate(path: String) {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: path))

        #expect(verdict.deniedCode == .volumeOrTopLevelDirectory)
    }

    /// Mesmo autorizando `/tmp` explicitamente, a pasta em si não sai.
    @Test func testRecusaPrivateTmpMesmoComTmpAutorizado() {
        let guardrail = guardAllowing(["/tmp"])
        #expect(!guardrail.evaluate(URL(fileURLWithPath: "/private/tmp")).isAllowed)
        #expect(!guardrail.evaluate(URL(fileURLWithPath: "/tmp")).isAllowed)
    }

    @Test func testCanonicalizacaoDeCaminhoInexistente() throws {
        let url = URL(fileURLWithPath: "/tmp/nao-existe-\(UUID().uuidString)/a/b.txt")
        let canonical = try #require(PathGuard.canonicalLocation(of: url))
        #expect(canonical.path.hasPrefix("/private/tmp/"))
        #expect(canonical.path.hasSuffix("/a/b.txt"))
    }

    // MARK: - Normalização

    /// Travessias de diretório não podem escapar do escopo.
    @Test func testRecusaTravessiaAcimaDaRaizAutorizada() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Users/teste/Library/Caches/../../../Documents/segredo.pdf"))

        #expect(!verdict.isAllowed)
        #expect(verdict.deniedCode == .pathTraversal)
    }

    /// `..` é recusado mesmo quando, resolvido, cairia dentro do escopo:
    /// não há motivo legítimo para um candidato conter travessia.
    @Test func testRecusaTravessiaMesmoQuandoTerminariaNoEscopo() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Users/teste/Library/Caches/a/../b.bin"))

        #expect(verdict.deniedCode == .pathTraversal)
    }

    /// Raiz autorizada com `..` é descartada: nunca vira "autoriza tudo".
    @Test func testRaizComTravessiaEDescartada() {
        let guardrail = guardAllowing(["/Users/teste/Library/Caches/../.."])
        #expect(guardrail.allowedRoots.isEmpty)
        #expect(!guardrail.evaluate(URL(fileURLWithPath: "/Users/teste/Documents/x.txt")).isAllowed)
    }

    @Test func testRecusaCaminhoRelativo() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "Caches/relativo.bin"))

        #expect(!verdict.isAllowed)
    }

    @Test func testRecusaCaminhoVazio() {
        let guardrail = guardAllowing([caches])
        // `URL(fileURLWithPath: "")` vira o diretório atual (caminho absoluto),
        // então não serve para exercitar o caso. `file:` tem `path` vazio.
        let verdict = guardrail.evaluate(URL(string: "file:")!)

        #expect(verdict.deniedCode == .emptyPath)
    }

    /// O escopo autorizado nunca inclui a própria raiz: apagar a pasta que o
    /// usuário autorizou é sempre uma operação diferente de limpar o conteúdo.
    @Test func testRecusaARaizAutorizadaElaMesma() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: caches))

        #expect(!verdict.isAllowed, "a raiz autorizada não pode ser removida, só o conteúdo dela")
    }

    // MARK: - Utilitários

    @Test func testDetectaDescendenciaEstrita() {
        let base = URL(fileURLWithPath: "/a/b")
        #expect(PathGuard.isStrictDescendant(URL(fileURLWithPath: "/a/b/c"), of: base, caseInsensitive: false))
        #expect(!(PathGuard.isStrictDescendant(URL(fileURLWithPath: "/a/b"), of: base, caseInsensitive: false)))
        #expect(!(PathGuard.isStrictDescendant(URL(fileURLWithPath: "/a/bc"), of: base, caseInsensitive: false)), "prefixo textual sem separador não é descendência")
    }
}
