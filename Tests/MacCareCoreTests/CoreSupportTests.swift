import Foundation
import Testing
@testable import MacCareCore

/// Formatação de bytes e persistência local.
@Suite("Formatação e histórico")
final class CoreSupportTests {

    /// Diretórios temporários criados pelos testes; removidos no `deinit`,
    /// que roda ao fim de cada teste — inclusive quando ele falha.
    private var temporaryDirectories: [URL] = []

    deinit {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Formatação

    @Test func testFormataEmUnidadesBinarias() {
        #expect(ByteSizeFormatter.format(1_073_741_824) == "1,0 GiB")
        #expect(ByteSizeFormatter.format(1_048_576) == "1,0 MiB")
        #expect(ByteSizeFormatter.format(820) == "820 bytes")
    }

    /// Acima de 100, a casa decimal vira ruído visual.
    @Test func testReduzCasasDecimaisEmValoresGrandes() {
        #expect(ByteSizeFormatter.format(150 * 1_073_741_824) == "150 GiB")
    }

    /// Valor negativo é dado corrompido; exibir "-5 MiB" seria pior que omitir.
    @Test func testValoresNegativosSaoTratadosComoZero() {
        #expect(ByteSizeFormatter.format(-1_048_576) == "0 bytes")
    }

    /// Fração fora do intervalo é fixada nos extremos.
    @Test func testPorcentagemFixaValoresForaDoIntervalo() {
        #expect(ByteSizeFormatter.percent(1.4) == "100%")
        #expect(ByteSizeFormatter.percent(-0.3) == "0%")
        #expect(ByteSizeFormatter.percent(.nan) == "0%")
    }

    @Test func testCompactaParaGrafico() {
        #expect(ByteSizeFormatter.compact(1_073_741_824) == "1,0 GB")
    }

    // MARK: - Histórico

    private func makeTempLog() throws -> (log: JSONLOperationLog, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccare-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("oplog.jsonl")
        temporaryDirectories.append(directory)
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

    @Test func testGravaELeHistoricoEmOrdemRecentePrimeiro() async throws {
        let (log, _) = try makeTempLog()
        let agora = Date()

        try await log.append(record(at: agora.addingTimeInterval(-3600), path: "/antigo"))
        try await log.append(record(at: agora, path: "/recente"))

        let all = try await log.all()
        #expect(all.count == 2)
        #expect(all.first?.affectedPaths.first == "/recente")
    }

    @Test func testHistoricoVazioNaoFalha() async throws {
        let (log, _) = try makeTempLog()
        let all = try await log.all()
        #expect(all.isEmpty)
    }

    /// Uma linha truncada por encerramento abrupto é descartada, não fatal.
    ///
    /// Um histórico que impede o app de abrir por causa de um registro
    /// corrompido seria pior do que perder um registro.
    @Test func testLinhaCorrompidaNaoImpedeLeituraDoResto() async throws {
        let (log, url) = try makeTempLog()
        try await log.append(record(at: Date(), path: "/valido"))

        // Simula uma escrita interrompida: ACRESCENTA uma linha truncada ao
        // final. (Gravar com `.atomic` substituiria o arquivo inteiro e
        // apagaria também o registro íntegro que o teste quer preservar.)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"quebrado\": tru".utf8))
        try handle.close()

        let all = try await log.all()
        #expect(all.count == 1, "o registro íntegro deve continuar legível")
    }

    @Test func testLimpaHistorico() async throws {
        let (log, _) = try makeTempLog()
        try await log.append(record(at: Date(), path: "/x"))
        try await log.clear()
        let all = try await log.all()
        #expect(all.isEmpty)
    }

    /// A exportação remove o nome do usuário dos caminhos.
    @Test func testExportacaoRedigeNomeDoUsuario() {
        let original = record(at: Date(), path: "/Users/rodrigo/Downloads/video.mov")
        let redacted = original.redacted(homePath: "/Users/rodrigo")

        #expect(redacted.affectedPaths.first == "~/Downloads/video.mov")
        #expect(!(redacted.affectedPaths.contains { $0.contains("rodrigo") }), "dado pessoal não pode vazar na exportação")
    }

    @Test func testRedacaoSemCaminhoCasaDevolveOriginal() {
        let original = record(at: Date(), path: "/tmp/x")
        #expect(original.redacted(homePath: nil).affectedPaths == original.affectedPaths)
    }
}
