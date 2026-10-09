import XCTest
@testable import MacCareCore

/// Formatação de bytes e persistência local.
final class CoreSupportTests: XCTestCase {

    // MARK: - Formatação

    func testFormataEmUnidadesBinarias() {
        XCTAssertEqual(ByteSizeFormatter.format(1_073_741_824), "1,0 GiB")
        XCTAssertEqual(ByteSizeFormatter.format(1_048_576), "1,0 MiB")
        XCTAssertEqual(ByteSizeFormatter.format(820), "820 bytes")
    }

    /// Acima de 100, a casa decimal vira ruído visual.
    func testReduzCasasDecimaisEmValoresGrandes() {
        XCTAssertEqual(ByteSizeFormatter.format(150 * 1_073_741_824), "150 GiB")
    }

    /// Valor negativo é dado corrompido; exibir "-5 MiB" seria pior que omitir.
    func testValoresNegativosSaoTratadosComoZero() {
        XCTAssertEqual(ByteSizeFormatter.format(-1_048_576), "0 bytes")
    }

    /// Fração fora do intervalo é fixada nos extremos.
    func testPorcentagemFixaValoresForaDoIntervalo() {
        XCTAssertEqual(ByteSizeFormatter.percent(1.4), "100%")
        XCTAssertEqual(ByteSizeFormatter.percent(-0.3), "0%")
        XCTAssertEqual(ByteSizeFormatter.percent(.nan), "0%")
    }

    func testCompactaParaGrafico() {
        XCTAssertEqual(ByteSizeFormatter.compact(1_073_741_824), "1,0 GB")
    }

    // MARK: - Histórico

    private func makeTempLog() throws -> (log: JSONLOperationLog, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccare-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("oplog.jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (JSONLOperationLog(fileURL: url), url)
    }

    private func record(at date: Date, path: String) -> OperationRecord {
        OperationRecord(
            performedAt: date,
            kind: .smartCleanup,
            strategy: "Mover para a Lixeira",
            itemCount: 1,
            succeededCount: 1,
            skippedCount: 0,
            failedCount: 0,
            affectedPaths: [path],
            accounting: SpaceAccounting(identified: 100, selected: 100),
            notes: []
        )
    }

    func testGravaELeHistoricoEmOrdemRecentePrimeiro() async throws {
        let (log, _) = try makeTempLog()
        let agora = Date()

        try await log.append(record(at: agora.addingTimeInterval(-3600), path: "/antigo"))
        try await log.append(record(at: agora, path: "/recente"))

        let all = try await log.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.affectedPaths.first, "/recente")
    }

    func testHistoricoVazioNaoFalha() async throws {
        let (log, _) = try makeTempLog()
        XCTAssertTrue(try await log.all().isEmpty)
    }

    /// Uma linha truncada por encerramento abrupto é descartada, não fatal.
    ///
    /// Um histórico que impede o app de abrir por causa de um registro
    /// corrompido seria pior do que perder um registro.
    func testLinhaCorrompidaNaoImpedeLeituraDoResto() async throws {
        let (log, url) = try makeTempLog()
        try await log.append(record(at: Date(), path: "/valido"))

        try Data("{\"quebrado\": tru".utf8).write(to: url, options: .atomic)

        let all = try await log.all()
        XCTAssertEqual(all.count, 1, "o registro íntegro deve continuar legível")
    }

    func testLimpaHistorico() async throws {
        let (log, _) = try makeTempLog()
        try await log.append(record(at: Date(), path: "/x"))
        try await log.clear()
        XCTAssertTrue(try await log.all().isEmpty)
    }

    /// A exportação remove o nome do usuário dos caminhos.
    func testExportacaoRedigeNomeDoUsuario() {
        let original = record(at: Date(), path: "/Users/rodrigo/Downloads/video.mov")
        let redacted = original.redacted(homePath: "/Users/rodrigo")

        XCTAssertEqual(redacted.affectedPaths.first, "~/Downloads/video.mov")
        XCTAssertFalse(
            redacted.affectedPaths.contains { $0.contains("rodrigo") },
            "dado pessoal não pode vazar na exportação"
        )
    }

    func testRedacaoSemCaminhoCasaDevolveOriginal() {
        let original = record(at: Date(), path: "/tmp/x")
        XCTAssertEqual(original.redacted(homePath: nil).affectedPaths, original.affectedPaths)
    }
}
