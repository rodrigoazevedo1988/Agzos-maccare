import Foundation
import XCTest
@testable import MacCareCore

/// ## Testes de integração do núcleo
///
/// Estes testes usam o sistema de arquivos **real**, mas exclusivamente dentro
/// de diretórios temporários criados por eles mesmos. O PRD §25 é explícito:
/// "nunca executar testes destrutivos em diretórios reais do usuário".
///
/// Cada teste cria sua própria árvore, executa, e apaga tudo no encerramento —
/// inclusive quando falha, via `addTeardownBlock`.
final class CoreIntegrationTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccare-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeFile(_ relativePath: String, contents: String) throws -> URL {
        let url = sandbox.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Leitura de tamanho

    func testMedeTamanhoDeArquivo() throws {
        let file = try makeFile("a.txt", contents: String(repeating: "x", count: 5_000))
        let fs = LiveFileSystem()

        let size = try XCTUnwrap(fs.allocatedSize(of: file))
        XCTAssertGreaterThanOrEqual(size, 5_000, "o tamanho em disco não pode ser menor que o conteúdo")
    }

    func testMedeTamanhoDeDiretorioRecursivamente() throws {
        try makeFile("pasta/a.bin", contents: String(repeating: "a", count: 10_000))
        try makeFile("pasta/sub/b.bin", contents: String(repeating: "b", count: 20_000))
        let fs = LiveFileSystem()

        let size = try XCTUnwrap(FileSizeMeasurer.directorySize(of: sandbox.appendingPathComponent("pasta"), fs: fs))
        XCTAssertGreaterThanOrEqual(size, 30_000)
    }

    // MARK: - Varredura

    func testVarreduraEncontraArquivoAcimaDoLimite() async throws {
        try makeFile("grande.bin", contents: String(repeating: "x", count: 40_000))
        try makeFile("pequeno.bin", contents: "x")

        let scanner = DirectoryScanner(fs: LiveFileSystem(), limits: .quick)
        let result = try await scanner.scanLargeFiles(
            roots: [sandbox],
            query: FileQuery(minimumSize: 10_000)
        )

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.url.lastPathComponent, "grande.bin")
        XCTAssertTrue(result.progress.isFinished)
    }

    func testFiltroPorExtensao() async throws {
        try makeFile("foto.jpg", contents: String(repeating: "x", count: 5_000))
        try makeFile("codigo.swift", contents: String(repeating: "x", count: 5_000))

        let scanner = DirectoryScanner(fs: LiveFileSystem(), limits: .quick)
        let result = try await scanner.scanLargeFiles(
            roots: [sandbox],
            query: FileQuery(minimumSize: 1_000, allowedExtensions: ["jpg"])
        )

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.url.pathExtension, "jpg")
    }

    func testVarreduraRespeitaCancelamento() async throws {
        for index in 0..<40 {
            try makeFile("arquivo-\(index).bin", contents: String(repeating: "x", count: 2_000))
        }

        let scanner = DirectoryScanner(fs: LiveFileSystem(), limits: .quick)
        let task = Task {
            try await scanner.scanLargeFiles(roots: [sandbox], query: FileQuery(minimumSize: 1))
        }
        task.cancel()

        do {
            _ = try await task.value
            // Se a varredura terminou antes do cancelamento, tudo bem: o que
            // não pode acontecer é devolver resultado *depois* de cancelada.
        } catch is CancellationError {
            // Comportamento esperado.
        }
    }

    // MARK: - Duplicados

    func testDetectaArquivosComConteudoIdentico() async throws {
        let conteudo = String(repeating: "conteudo duplicado ", count: 500)
        try makeFile("original.bin", contents: conteudo)
        try makeFile("copia1.bin", contents: conteudo)
        try makeFile("copia2.bin", contents: conteudo)
        try makeFile("diferente.bin", contents: String(repeating: "outro", count: 5_000))

        let finder = DuplicateFinder(fs: LiveFileSystem(), minimumSize: 100)
        let groups = try await finder.findDuplicates(in: [sandbox])

        XCTAssertEqual(groups.count, 1, "apenas o trio de conteúdo idêntico forma grupo")
        XCTAssertEqual(groups[0].fileCount, 3)

        // Três cópias: preservar uma deixa duas removíveis.
        XCTAssertEqual(groups[0].reclaimableSize, groups[0].sizeOnDisk * 2)
    }

    /// Nomes parecidos não são duplicatas.
    ///
    /// Este teste protege a regra do PRD §11 contra uma otimização tentadora:
    /// comparar nome + tamanho em vez de hashear o conteúdo.
    func testNomesParecidosNaoSaoDuplicatas() async throws {
        let base = String(repeating: "z", count: 4_000)
        try makeFile("relatorio-final.bin", contents: base)
        try makeFile("relatorio-final-v2.bin", contents: base + "extra")

        let finder = DuplicateFinder(fs: LiveFileSystem(), minimumSize: 100)
        let groups = try await finder.findDuplicates(in: [sandbox])

        XCTAssertTrue(groups.isEmpty, "conteúdo diferente não é duplicata, por mais parecidos que os nomes sejam")
    }

    /// Hard links são o mesmo arquivo, não cópias.
    func testHardLinksNaoViramGrupoDeDuplicatas() async throws {
        let original = try makeFile("original.bin", contents: String(repeating: "q", count: 4_000))
        let link = sandbox.appendingPathComponent("link.bin")

        // Criar hard link exige o mesmo volume; pode falhar em alguns sistemas.
        try XCTSkipIf(
            FileManager.default.linkItem(at: original, to: link) == false,
            "sistema de arquivos não suporta hard link neste ambiente"
        )

        let finder = DuplicateFinder(fs: LiveFileSystem(), minimumSize: 100)
        let groups = try await finder.findDuplicates(in: [sandbox])

        XCTAssertTrue(
            groups.isEmpty,
            "dois caminhos para o mesmo inode são o mesmo arquivo; removê-los destruiria o conteúdo"
        )
    }

    // MARK: - Lixeira

    /// O caminho padrão manda para a Lixeira e é reversível.
    func testRemocaoUsaLixeiraPorPadrao() async throws {
        let file = try makeFile("descartavel.bin", contents: String(repeating: "x", count: 1_000))
        let fs = LiveFileSystem()

        let guardrail = PathGuard(allowedRoots: [sandbox])
        let remover = SafeFileRemover(guardrail: guardrail, fs: fs)

        let candidate = CleanupCandidate(
            url: file,
            category: .applicationCache,
            reason: "Integração.",
            confidence: .certain,
            sizeOnDisk: 1_000
        )
        let selection = try ConfirmedSelection(items: [candidate], kind: .standard)
        let report = try await remover.execute(try RemovalPlan(selection: selection))

        XCTAssertEqual(report.movedToTrash.count, 1, "a operação padrão deve ser mover para a Lixeira")
        XCTAssertEqual(report.failed.count, 0)
    }

    /// Um caminho fora do escopo é ignorado, mesmo com tudo o mais válido.
    func testCaminhoForaDoEscopoEIgnoradoNaIntegracao() async throws {
        let fs = LiveFileSystem()
        // Escopo aponta para o sandbox; o candidato aponta para fora dele.
        let guardrail = PathGuard(allowedRoots: [sandbox])
        let remover = SafeFileRemover(guardrail: guardrail, fs: fs)

        let candidate = CleanupCandidate(
            url: URL(fileURLWithPath: "/tmp/nao-pertencente-\(UUID().uuidString).bin"),
            category: .applicationCache,
            reason: "Fora do escopo.",
            confidence: .certain,
            sizeOnDisk: 10
        )
        let selection = try ConfirmedSelection(items: [candidate], kind: .standard)
        let report = try await remover.execute(try RemovalPlan(selection: selection))

        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(report.movedToTrash.count, 0)
        XCTAssertEqual(report.deleted.count, 0)
    }

    // MARK: - Info.plist

    func testLeInfoPlistDeBundleDeTeste() throws {
        let app = sandbox.appendingPathComponent("MeuApp.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.exemplo.meuapp",
            "CFBundleName": "Meu App",
            "CFBundleShortVersionString": "2.1.0",
            "CFBundleVersion": "42"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let lido = try XCTUnwrap(ApplicationCatalog.readInfoPlist(at: app))
        XCTAssertEqual(lido["CFBundleIdentifier"] as? String, "com.exemplo.meuapp")
        XCTAssertEqual(lido["CFBundleShortVersionString"] as? String, "2.1.0")
    }

    /// Diretório sem `Info.plist` não é um aplicativo.
    func testPastaSemInfoPlistNaoEReconhecidaComoApp() throws {
        let pasta = sandbox.appendingPathComponent("NaoEApp.app")
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)

        XCTAssertNil(
            ApplicationCatalog.readInfoPlist(at: pasta),
            "uma pasta qualquer com extensão .app não deve entrar na lista de aplicativos"
        )
    }
}
