import XCTest
@testable import MacCareCore

/// ## Testes de segurança — `SafeFileRemover`
///
/// Verificam os critérios do PRD §25: "nenhuma exclusão sem confirmação",
/// "nenhuma exclusão de diretórios proibidos" e "comportamento com permissões
/// insuficientes". Todos rodam contra o `InMemoryFileSystem` — nenhum arquivo
/// real é criado ou destruído.
final class SafeFileRemoverTests: XCTestCase {

    private let home = "/Users/teste"
    private let caches = "/Users/teste/Library/Caches"

    private func makeGuard(roots: [String] = ["/Users/teste/Library/Caches"]) -> PathGuard {
        PathGuard(allowedRoots: roots.map { URL(fileURLWithPath: $0) })
    }

    private func cacheCandidate(
        _ name: String,
        size: Int64 = 1_000_000,
        category: CleanupCategory = .applicationCache
    ) -> CleanupCandidate {
        CleanupCandidate(
            url: URL(fileURLWithPath: "\(caches)/\(name)"),
            category: category,
            reason: "Cache de teste.",
            confidence: .certain,
            sizeOnDisk: size
        )
    }

    // MARK: - Confirmação

    /// Nenhum plano executável existe sem uma confirmação válida.
    func testSelecaoVaziaERecusada() {
        XCTAssertThrowsError(try ConfirmedSelection(items: [], kind: .standard)) { error in
            XCTAssertEqual(error as? RemovalPlanError, .emptySelection)
        }
    }

    /// Categoria que pode conter dados do usuário exige confirmação reforçada.
    ///
    /// A Lixeira é o caso canônico: esvaziá-la é irreversível, e o usuário
    /// precisa ter dito isso de forma inequívoca.
    func testCategoriaArriscadaExigeConfirmacaoReforcada() {
        let items = [cacheCandidate("trash-item", category: .trash)]

        XCTAssertThrowsError(try ConfirmedSelection(items: items, kind: .standard)) { error in
            XCTAssertEqual(
                error as? RemovalPlanError,
                .insufficientConfirmation(required: .full, provided: .standard)
            )
        }

        XCTAssertNoThrow(try ConfirmedSelection(items: items, kind: .full))
    }

    func testConfirmacaoReforcadaAceitaCategoriaSegura() {
        XCTAssertNoThrow(try ConfirmedSelection(items: [cacheCandidate("seguro")], kind: .full))
    }

    /// Exclusão definitiva exige uma autorização separada da confirmação.
    func testExclusaoDefinitivaExigeAutorizacao() {
        let selection = try! ConfirmedSelection(items: [cacheCandidate("x")], kind: .standard)

        XCTAssertThrowsError(try RemovalPlan(selection: selection, strategy: .permanentlyDelete)) { error in
            XCTAssertEqual(error as? RemovalPlanError, .permanentDeletionNotAuthorized)
        }

        XCTAssertNoThrow(
            try RemovalPlan(selection: selection, strategy: .permanentlyDelete, allowPermanentDeletion: true)
        )
    }

    // MARK: - Execução

    /// O caminho padrão é a Lixeira, e **nada** é excluído permanentemente.
    func testExecucaoPadraoUsaLixeira() async throws {
        let fs = InMemoryFileSystem()
        fs.addFile("\(caches)/app.bin")
        let remover = SafeFileRemover(guardrail: makeGuard(), fs: fs)

        let selection = try ConfirmedSelection(items: [cacheCandidate("app.bin")], kind: .standard)
        let report = try await remover.execute(try RemovalPlan(selection: selection))

        XCTAssertEqual(report.movedToTrash.count, 1)
        XCTAssertEqual(fs.trashedPaths, ["\(caches)/app.bin"])
        XCTAssertTrue(fs.deletedPaths.isEmpty, "nada pode ser excluído sem autorização explícita")
    }

    /// Quando a Lixeira falha, o item é **mantido** e a falha é reportada.
    ///
    /// Este teste existe para impedir a "correção" mais tentadora e mais errada:
    /// um `catch` que apaga o arquivo direto quando o `trashItem` falha. O
    /// usuário pediu ir para a Lixeira; falhar é a resposta correta.
    func testFalhaAoMoverParaLixeiraNaoApagaSilenciosamente() async throws {
        let fs = InMemoryFileSystem()
        // O arquivo não existe no sistema de arquivos, então `moveToTrash` lança.
        let remover = SafeFileRemover(guardrail: makeGuard(), fs: fs)

        let selection = try ConfirmedSelection(items: [cacheCandidate("inexistente.bin")], kind: .standard)
        let report = try await remover.execute(try RemovalPlan(selection: selection))

        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(fs.deletedPaths.isEmpty)
        XCTAssertTrue(
            report.failed[0].reason?.contains("mantido intacto") == true,
            "a mensagem precisa dizer ao usuário que o arquivo está intacto"
        )
    }

    /// Item bloqueado pelo `PathGuard` é **ignorado**, não removido.
    func testItemProtegidoEIgnoradoComMotivo() async throws {
        let fs = InMemoryFileSystem()
        fs.addFile("/System/Library/alvo.dylib")
        // Escopo amplo, para provar que quem barra é a proteção, não o escopo.
        let remover = SafeFileRemover(guardrail: makeGuard(roots: ["/"]), fs: fs)

        let candidate = CleanupCandidate(
            url: URL(fileURLWithPath: "/System/Library/alvo.dylib"),
            category: .applicationCache,
            reason: "Teste adversarial.",
            confidence: .certain,
            sizeOnDisk: 500
        )
        let selection = try ConfirmedSelection(items: [candidate], kind: .standard)
        let report = try await remover.execute(try RemovalPlan(selection: selection))

        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(report.skipped[0].reason, PathGuardCode.protectedSystemPath.explanation)
        XCTAssertTrue(fs.trashedPaths.isEmpty)
        XCTAssertTrue(fs.deletedPaths.isEmpty)
    }

    /// Simulação produz relatório completo sem tocar em nada.
    func testSimulacaoNaoAlteraNenhumArquivo() async throws {
        let fs = InMemoryFileSystem()
        fs.addFile("\(caches)/a.bin")
        fs.addFile("\(caches)/b.bin")
        let remover = SafeFileRemover(guardrail: makeGuard(), fs: fs)

        let selection = try ConfirmedSelection(
            items: [cacheCandidate("a.bin"), cacheCandidate("b.bin")],
            kind: .standard
        )
        let report = try await remover.execute(try RemovalPlan(selection: selection, strategy: .simulate))

        XCTAssertEqual(report.outcomes.count, 2, "a simulação reporta todos os itens")
        XCTAssertTrue(fs.trashedPaths.isEmpty)
        XCTAssertTrue(fs.deletedPaths.isEmpty)
        XCTAssertEqual(report.accounting.releasedConfirmed, 0)
    }

    // MARK: - Contabilidade de espaço

    /// Mover para a Lixeira não libera espaço confirmado.
    ///
    /// A Lixeira vive no mesmo volume. Dizer "2 GB liberados" depois de mover
    /// coisas para lá é tecnicamente verdade só quando o usuário esvazia a
    /// lixeira — e o app não esvazia a lixeira sozinho.
    func testEspacoDaLixeiraNaoECountadoComoLiberado() async throws {
        let fs = InMemoryFileSystem()
        // O motor usa o tamanho MEDIDO na execução, não o declarado no
        // candidato; o arquivo em memória precisa ter o tamanho do cenário.
        fs.addFile("\(caches)/grande.bin", size: 2_000_000_000)
        fs.setVolume(available: 10_000_000_000, total: 500_000_000_000)
        let remover = SafeFileRemover(guardrail: makeGuard(), fs: fs)

        let selection = try ConfirmedSelection(items: [cacheCandidate("grande.bin", size: 2_000_000_000)], kind: .standard)
        let report = try await remover.execute(try RemovalPlan(selection: selection))

        XCTAssertEqual(report.accounting.releasedConfirmed, 0)
        XCTAssertEqual(report.accounting.releasedUnconfirmed, 2_000_000_000)
    }

    /// Espaço confirmado nunca excede o que foi efetivamente medido.
    func testEspacoConfirmadoRespeitaMedicao() async throws {
        let fs = InMemoryFileSystem()
        fs.addFile("\(caches)/alvo.bin")
        // Simula outro processo ocupando espaço entre as medições.
        fs.setVolume(available: 1_000, total: 1_000_000)
        let remover = SafeFileRemover(guardrail: makeGuard(), fs: fs)

        let selection = try ConfirmedSelection(items: [cacheCandidate("alvo.bin", size: 5_000)], kind: .standard)
        let report = try await remover.execute(
            try RemovalPlan(selection: selection, strategy: .permanentlyDelete, allowPermanentDeletion: true)
        )

        XCTAssertLessThanOrEqual(
            report.accounting.releasedConfirmed,
            5_000,
            "não se pode afirmar ter liberado mais do que o tamanho medido dos itens"
        )
    }

    // MARK: - Revalidação

    /// O caminho é revalidado **no momento da execução**, não só na análise.
    func testRevalidaCaminhoNoMomentoDaExecucao() async throws {
        let fs = InMemoryFileSystem()
        let remover = SafeFileRemover(guardrail: makeGuard(), fs: fs)

        // O candidato foi aprovado na análise com escopo amplo; o motor em
        // execução usa o escopo restrito real.
        let candidate = CleanupCandidate(
            url: URL(fileURLWithPath: "/Users/teste/Documents/segredo.pdf"),
            category: .applicationCache,
            reason: "Aprovado antes de o escopo mudar.",
            confidence: .certain,
            sizeOnDisk: 42
        )
        let selection = try ConfirmedSelection(items: [candidate], kind: .standard)
        let report = try await remover.execute(try RemovalPlan(selection: selection))

        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(fs.trashedPaths.isEmpty)
    }
}
