import Foundation
import Testing
@testable import MacCareCore

/// ## Testes de segurança — desinstalação
///
/// `/Applications` continua protegido para a limpeza geral; a desinstalação
/// usa uma autorização própria que permite exatamente um bundle e os
/// residuais dele. Estes testes provam os dois lados: o que entra e o que,
/// mesmo parecido, fica de fora. Tudo em `InMemoryFileSystem`.
@Suite("Segurança — desinstalação de aplicativos")
struct AppUninstallAuthorizationTests {

    private let home = URL(fileURLWithPath: "/Users/teste")
    private let appID = "com.exemplo.editor"
    private let appPath = "/Applications/Editor.app"

    /// Monta um sistema de arquivos com um app de terceiros válido.
    private func makeFileSystem(bundlePath: String? = nil) -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        let path = bundlePath ?? appPath
        fs.addDirectory(path)
        fs.addFile("\(path)/Contents/Info.plist", size: 2_000)
        fs.addFile("\(path)/Contents/MacOS/Editor", size: 5_000_000)
        return fs
    }

    private func authorize(
        _ path: String? = nil,
        fs: InMemoryFileSystem,
        identifiers: [String: String]? = nil,
        ownBundle: String? = nil,
        ownBundleIdentifier: String? = nil,
        running: LockedValue<Set<String>> = LockedValue([])
    ) throws -> AppUninstallAuthorization {
        let ids = identifiers ?? [path ?? appPath: appID]
        return try AppUninstallAuthorization(
            bundle: URL(fileURLWithPath: path ?? appPath),
            home: home,
            ownBundle: ownBundle.map { URL(fileURLWithPath: $0) },
            ownBundleIdentifier: ownBundleIdentifier,
            fs: fs,
            bundleIdentifierReader: { ids[$0.path] },
            isRunning: { id in running.current.contains(id) }
        )
    }

    private func candidate(_ path: String) -> CleanupCandidate {
        CleanupCandidate(
            url: URL(fileURLWithPath: path),
            category: .applicationLeftovers,
            reason: "Desinstalação.",
            confidence: .certain,
            sizeOnDisk: 1_000
        )
    }

    // MARK: - Aceito

    @Test func testBundleValidoEResiduaisSaoAceitos() throws {
        let fs = makeFileSystem()
        let auth = try authorize(fs: fs)

        #expect(auth.evaluate(URL(fileURLWithPath: appPath)).isAllowed)
        for leftover in [
            "/Users/teste/Library/Application Support/\(appID)",
            "/Users/teste/Library/Caches/\(appID)",
            "/Users/teste/Library/Preferences/\(appID).plist",
            "/Users/teste/Library/Containers/\(appID)",
            "/Users/teste/Library/Group Containers/\(appID)",
            "/Users/teste/Library/Saved Application State/\(appID).savedState",
            "/Users/teste/Library/Logs/\(appID)",
            "/Users/teste/Library/HTTPStorages/\(appID)",
            "/Users/teste/Library/WebKit/\(appID)",
            "/Users/teste/Library/LaunchAgents/\(appID).plist"
        ] {
            #expect(auth.evaluate(URL(fileURLWithPath: leftover)).isAllowed, "\(leftover)")
        }
        #expect(!auth.permitsPermanentDeletion)
    }

    @Test func testGroupContainerComTeamIDEAceito() throws {
        let fs = makeFileSystem()
        fs.addDirectory("/Users/teste/Library/Group Containers/ABCDE12345.\(appID)")
        fs.addDirectory("/Users/teste/Library/Group Containers/group.\(appID)")
        let auth = try authorize(fs: fs)

        #expect(auth.evaluate(URL(fileURLWithPath: "/Users/teste/Library/Group Containers/ABCDE12345.\(appID)")).isAllowed)
        #expect(!auth.evaluate(URL(fileURLWithPath: "/Users/teste/Library/Group Containers/group.\(appID)")).isAllowed)
        #expect(!AppUninstallAuthorization.isTeamPrefixedGroup("abcde12345.\(appID)", bundleIdentifier: appID))
        #expect(!AppUninstallAuthorization.isTeamPrefixedGroup("ABCDE1234.\(appID)", bundleIdentifier: appID))
    }

    // MARK: - Recusado na criação

    @Test func testCaminhoAninhadoEmApplicationsERecusado() {
        let nested = "/Applications/Utilitarios/Editor.app"
        let fs = makeFileSystem(bundlePath: nested)
        #expect(throws: AppUninstallError.notDirectlyInApplicationsFolder) {
            try authorize(nested, fs: fs, identifiers: [nested: appID])
        }
    }

    @Test func testItemDentroDoBundleERecusado() {
        let fs = makeFileSystem()
        let inner = "\(appPath)/Contents/MacOS/Editor"
        #expect(throws: AppUninstallError.notDirectlyInApplicationsFolder) {
            try authorize(inner, fs: fs, identifiers: [inner: appID])
        }
    }

    @Test func testPastaApplicationsElaMesmaERecusada() {
        let fs = InMemoryFileSystem()
        fs.addDirectory("/Applications")
        fs.addFile("/Applications/Contents/Info.plist")
        #expect(throws: AppUninstallError.notDirectlyInApplicationsFolder) {
            try authorize("/Applications", fs: fs, identifiers: ["/Applications": appID])
        }
    }

    @Test func testAppForaDeApplicationsERecusado() {
        let path = "/Users/teste/Downloads/Editor.app"
        let fs = makeFileSystem(bundlePath: path)
        #expect(throws: AppUninstallError.notDirectlyInApplicationsFolder) {
            try authorize(path, fs: fs, identifiers: [path: appID])
        }
    }

    @Test func testAppDoSistemaERecusado() {
        let path = "/System/Applications/Calculator.app"
        let fs = makeFileSystem(bundlePath: path)
        #expect(throws: AppUninstallError.notDirectlyInApplicationsFolder) {
            try authorize(path, fs: fs, identifiers: [path: "com.apple.calculator"])
        }
    }

    @Test func testAppDaAppleEmApplicationsERecusado() {
        let path = "/Applications/Safari.app"
        let fs = makeFileSystem(bundlePath: path)
        #expect(throws: AppUninstallError.appleApplication) {
            try authorize(path, fs: fs, identifiers: [path: "com.apple.Safari"])
        }
    }

    @Test func testProprioBundleERecusado() {
        let path = "/Applications/MacCare.app"
        let fs = makeFileSystem(bundlePath: path)
        #expect(throws: AppUninstallError.ownApplication) {
            try authorize(path, fs: fs, identifiers: [path: "com.agzos.MacCare"], ownBundle: path)
        }
        // Mesmo instalado em outro lugar, o identificador denuncia.
        #expect(throws: AppUninstallError.ownApplication) {
            try authorize(path, fs: fs, identifiers: [path: "com.agzos.MacCare"], ownBundleIdentifier: "com.agzos.MacCare")
        }
    }

    @Test func testBundleQueELinkSimbolicoERecusado() {
        let fs = InMemoryFileSystem()
        fs.addSymlink("/Applications/Atalho.app", to: "/System/Applications/Calculator.app")
        #expect(throws: AppUninstallError.symlinkedBundle) {
            try authorize("/Applications/Atalho.app", fs: fs, identifiers: ["/Applications/Atalho.app": appID])
        }
    }

    @Test func testBundleSemInfoPlistERecusado() {
        let fs = InMemoryFileSystem()
        fs.addDirectory(appPath)
        #expect(throws: AppUninstallError.invalidBundle) { try authorize(fs: fs) }
    }

    @Test func testBundleSemIdentificadorERecusado() {
        let fs = makeFileSystem()
        #expect(throws: AppUninstallError.invalidBundle) { try authorize(fs: fs, identifiers: [:]) }
    }

    @Test func testAppAbertoERecusado() {
        let fs = makeFileSystem()
        #expect(throws: AppUninstallError.applicationIsRunning) {
            try authorize(fs: fs, running: LockedValue([appID]))
        }
    }

    @Test func testTravessiaERecusada() {
        let fs = makeFileSystem()
        let path = "/Applications/../Applications/Editor.app"
        #expect(throws: AppUninstallError.notDirectlyInApplicationsFolder) {
            try authorize(path, fs: fs, identifiers: [path: appID])
        }
    }

    // MARK: - Escopo exato

    @Test func testSoOsCaminhosExatosSaoAceitos() throws {
        let fs = makeFileSystem()
        let auth = try authorize(fs: fs)

        for path in [
            "\(appPath)/Contents/MacOS/Editor",                       // filho do bundle
            "/Applications/Outro.app",                                // outro app
            "/Applications",                                          // a pasta
            "/Users/teste/Library/Caches/\(appID)/sub/arquivo",       // filho de residual
            "/Users/teste/Library/Caches/com.exemplo.outro",          // outro identificador
            "/Users/teste/Library/Application Support",               // pasta-mãe
            "/Users/teste/Documents/\(appID)",                        // fora de ~/Library
            "/Library/Application Support/\(appID)",                  // nível de sistema
            "/Users/teste/Library/Caches/../Caches/\(appID)"          // travessia
        ] {
            #expect(!auth.evaluate(URL(fileURLWithPath: path)).isAllowed, "\(path) não pode ser autorizado")
        }
    }

    // MARK: - Revalidação na execução

    @Test func testAppAbertoDepoisDaAutorizacaoERecusadoNaExecucao() throws {
        let fs = makeFileSystem()
        let running = LockedValue<Set<String>>([])
        let auth = try authorize(fs: fs, running: running)

        running.withLock { $0.insert(appID) }

        #expect(auth.evaluate(URL(fileURLWithPath: appPath)).deniedCode == .applicationIsRunning)
        #expect(auth.evaluate(URL(fileURLWithPath: "/Users/teste/Library/Caches/\(appID)")).deniedCode == .applicationIsRunning)
    }

    @Test func testBundleTrocadoPorLinkDepoisDaAutorizacaoERecusado() throws {
        let fs = makeFileSystem()
        let auth = try authorize(fs: fs)

        try fs.remove(at: URL(fileURLWithPath: appPath))
        fs.addSymlink(appPath, to: "/System/Applications/Calculator.app")

        #expect(!auth.evaluate(URL(fileURLWithPath: appPath)).isAllowed)
    }

    // MARK: - Execução completa

    @Test func testDesinstalacaoMoveSoBundleEResiduaisParaLixeira() async throws {
        let fs = makeFileSystem()
        let caches = "/Users/teste/Library/Caches/\(appID)"
        let documento = "/Users/teste/Documents/importante.txt"
        let outroApp = "/Applications/Outro.app"
        fs.addDirectory(caches)
        fs.addFile(documento)
        fs.addDirectory(outroApp)

        let auth = try authorize(fs: fs)
        let remover = SafeFileRemover(guardrail: auth, fs: fs)
        let selection = try ConfirmedSelection(
            items: [candidate(appPath), candidate(caches), candidate(documento), candidate(outroApp)],
            kind: .standard
        )
        let report = try await remover.execute(try RemovalPlan(selection: selection))

        #expect(Set(fs.trashedPaths) == [appPath, caches])
        #expect(report.skipped.count == 2)
        #expect(fs.deletedPaths.isEmpty)
    }

    @Test func testDesinstalacaoNuncaExcluiDefinitivamente() async throws {
        let fs = makeFileSystem()
        let auth = try authorize(fs: fs)
        let remover = SafeFileRemover(guardrail: auth, fs: fs)
        let selection = try ConfirmedSelection(items: [candidate(appPath)], kind: .full)
        let plan = try RemovalPlan(selection: selection, strategy: .permanentlyDelete, allowPermanentDeletion: true)

        await #expect(throws: RemovalPlanError.permanentDeletionNotAuthorized) {
            try await remover.execute(plan)
        }
        #expect(fs.deletedPaths.isEmpty)
        #expect(fs.trashedPaths.isEmpty)
    }

    /// `/Applications` continua protegido para a limpeza geral.
    @Test func testLimpezaGeralContinuaRecusandoApplications() {
        let guardrail = PathGuard(allowedRoots: [URL(fileURLWithPath: "/")])
        #expect(guardrail.evaluate(URL(fileURLWithPath: appPath)).deniedCode == .protectedSystemPath)
    }
}
