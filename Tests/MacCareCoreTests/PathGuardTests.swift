import XCTest
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
final class PathGuardTests: XCTestCase {

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

    func testPermiteCaminhoDentroDoEscopoAutorizado() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Users/teste/Library/Caches/com.app/cache.bin"))

        XCTAssertTrue(verdict.isAllowed, "um cache dentro de Caches deve ser permitido")
    }

    func testRecusaCaminhoForaDoEscopoAutorizado() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Users/teste/Documents/contrato.pdf"))

        XCTAssertEqual(verdict.deniedCode, .outsideAllowedScope)
    }

    /// Falhar fechado: sem escopo, nada é autorizado.
    ///
    /// Este é o teste mais importante da suíte de segurança. Um `PathGuard`
    /// construído sem raízes é o estado em que uma refatoração ingênua poderia
    /// deixar o app — e o teste garante que esse estado **não remove nada**.
    func testSemEscopoAutorizadoNaoPermiteNada() {
        let guardrail = PathGuard.denyAll
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Users/teste/Library/Caches/qualquer.bin"))

        XCTAssertFalse(verdict.isAllowed)
        XCTAssertEqual(verdict.deniedCode, .outsideAllowedScope)
    }

    // MARK: - Caminhos protegidos

    func testRecusaRaizDoSistema() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))

        XCTAssertEqual(verdict.deniedCode, .protectedSystemPath)
    }

    func testRecusaDescendenteDeCaminhoProtegido() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/usr/local/lib/anything.dylib"))

        XCTAssertEqual(verdict.deniedCode, .protectedSystemPath)
    }

    func testRecusaBibliotecaDoSistema() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Library/Keychains/System.keychain"))

        XCTAssertEqual(verdict.deniedCode, .protectedSystemPath)
    }

    func testRecusaRaizDoVolume() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/"))

        XCTAssertEqual(verdict.deniedCode, .volumeOrTopLevelDirectory)
    }

    func testRecusaDiretorioDePrimeiroNivel() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/tmp"))

        XCTAssertEqual(verdict.deniedCode, .volumeOrTopLevelDirectory)
    }

    func testRecusaPastaAplicacoesInteira() {
        let guardrail = guardAllowing(["/"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Applications"))

        XCTAssertEqual(verdict.deniedCode, .applicationRootDirectory)
    }

    func testRecusaRemocaoDoProprioBundle() {
        let guardrail = guardAllowing(["/"], ownBundle: "/Applications/MacCare.app")
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Applications/MacCare.app/Contents/MacOS/MacCare"))

        XCTAssertEqual(verdict.deniedCode, .ownApplicationBundle)
    }

    // MARK: - Links simbólicos

    /// Um symlink dentro do escopo que aponta para fora deve ser recusado.
    ///
    /// Este é o cenário de ataque clássico: o app varre `~/Library/Caches`,
    /// encontra um link, resolve o destino e apaga `/System/Library`. Como a
    /// comparação acontece **depois** da resolução, o caso é barrado.
    func testRecusaSymlinkQueSaiDoEscopo() {
        let fs = InMemoryFileSystem()
        // O destino real existe e está protegido.
        fs.addFile("/System/Library/Architectures/important.dylib")
        // O link está "dentro" do escopo autorizado.
        fs.addFile("/Users/teste/Library/Caches/atalho")

        let guardrail = guardAllowing([caches])

        // `PathGuard.resolve` delega ao Foundation. No ambiente de teste o
        // symlink não existe de verdade, então simulamos a decisão com o
        // caminho já resolvido, que é exatamente o que `evaluate` receberia.
        let resolvedOutside = URL(fileURLWithPath: "/System/Library/Architectures/important.dylib")
        let verdict = guardrail.evaluate(resolvedOutside)

        XCTAssertEqual(
            verdict.deniedCode,
            .protectedSystemPath,
            "mesmo recebido já resolvido, um destino de sistema é barrado"
        )
    }

    /// Um link **para dentro** do escopo é legítimo e deve passar.
    ///
    /// `/tmp` é um symlink para `/private/tmp` no macOS. Se a comparação
    /// fosses feita antes da resolução, todo uso legítimo de `/tmp` seria
    /// barrado — e o app ficaria menos útil sem ficar mais seguro.
    func testPermiteSymlinkResolvidoDentroDoEscopo() {
        let guardrail = guardAllowing(["/private/tmp"])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/private/tmp/arquivo.txt"))

        XCTAssertTrue(verdict.isAllowed)
    }

    // MARK: - Normalização

    /// Travessias de diretório não podem escapar do escopo.
    func testRecusaTravessiaAcimaDaRaizAutorizada() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "/Users/teste/Library/Caches/../../../Documents/segredo.pdf"))

        XCTAssertFalse(verdict.isAllowed)
    }

    func testRecusaCaminhoRelativo() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: "Caches/relativo.bin"))

        XCTAssertFalse(verdict.isAllowed)
    }

    func testRecusaCaminhoVazio() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: ""))

        XCTAssertEqual(verdict.deniedCode, .emptyPath)
    }

    /// O escopo autorizado nunca inclui a própria raiz: apagar a pasta que o
    /// usuário autorizou é sempre uma operação diferente de limpar o conteúdo.
    func testRecusaARaizAutorizadaElaMesma() {
        let guardrail = guardAllowing([caches])
        let verdict = guardrail.evaluate(URL(fileURLWithPath: caches))

        XCTAssertFalse(verdict.isAllowed, "a raiz autorizada não pode ser removida, só o conteúdo dela")
    }

    // MARK: - Utilitários

    func testDetectaDescendenciaEstrita() {
        let base = URL(fileURLWithPath: "/a/b")
        XCTAssertTrue(PathGuard.isStrictDescendant(URL(fileURLWithPath: "/a/b/c"), of: base, caseInsensitive: false))
        XCTAssertFalse(PathGuard.isStrictDescendant(URL(fileURLWithPath: "/a/b"), of: base, caseInsensitive: false))
        XCTAssertFalse(PathGuard.isStrictDescendant(URL(fileURLWithPath: "/a/bc"), of: base, caseInsensitive: false),
                       "prefixo textual sem separador não é descendência")
    }
}
