import XCTest
@testable import MacCareCore

/// Regras de seleção e contabilidade da análise consolidada.
final class CleanupPlanningTests: XCTestCase {

    private let caches = "/Users/teste/Library/Caches"

    private func candidate(
        _ name: String,
        category: CleanupCategory,
        confidence: Confidence,
        size: Int64? = 1_000
    ) -> CleanupCandidate {
        CleanupCandidate(
            url: URL(fileURLWithPath: "\(caches)/\(name)"),
            category: category,
            reason: "Teste.",
            confidence: confidence,
            sizeOnDisk: size
        )
    }

    // MARK: - Seleção padrão

    /// Só o que é confirmado e seguro vem marcado.
    func testPreselecionaSomenteConfirmadoESeguro() {
        XCTAssertTrue(candidate("cache", category: .applicationCache, confidence: .certain).isPreselectedByDefault)
        XCTAssertFalse(candidate("grande", category: .largeFiles, confidence: .certain).isPreselectedByDefault,
                       "arquivo grande nunca vem marcado, por mais certo que esteja")
        XCTAssertFalse(candidate("dup", category: .duplicates, confidence: .certain).isPreselectedByDefault)
        XCTAssertFalse(candidate("dl", category: .oldDownloads, confidence: .certain).isPreselectedByDefault)
        XCTAssertFalse(candidate("inc", category: .applicationCache, confidence: .uncertain).isPreselectedByDefault)
    }

    /// Categorias que podem conter dados do usuário exigem confirmação reforçada.
    func testCategoriasArriscadasExigemConfirmacaoReforcada() {
        for category in [CleanupCategory.trash, .duplicates, .largeFiles, .oldDownloads, .browserData] {
            XCTAssertTrue(
                category.requiresReinforcedConfirmation,
                "\(category) deveria exigir confirmação reforçada"
            )
        }
        for category in [CleanupCategory.applicationCache, .oldLogs, .temporaryFiles] {
            XCTAssertFalse(
                category.requiresReinforcedConfirmation,
                "\(category) é regenerável; confirmação padrão basta"
            )
        }
    }

    // MARK: - Agregação

    /// Itens sem tamanho conhecido não entram no total.
    ///
    /// Somar zero para o que não conseguimos medir faria o número parecer
    /// exato quando não é. A interface sinaliza a existência desses itens.
    func testTotalIgnoraItensSemTamanhoConhecido() {
        let group = CleanupCategoryGroup(category: .applicationCache, candidates: [
            candidate("a", category: .applicationCache, confidence: .certain, size: 1_000),
            candidate("b", category: .applicationCache, confidence: .certain, size: nil),
            candidate("c", category: .applicationCache, confidence: .certain, size: 2_000)
        ])

        XCTAssertEqual(group.measurableSize, 3_000)
        XCTAssertTrue(group.hasUnmeasuredItems, "a UI precisa avisar que parte não foi medida")
    }

    /// O mesmo caminho em duas categorias conta uma vez só.
    ///
    /// Sem isso, a estimativa de espaço recuperável é inflada — e um número
    /// inflado é a forma mais fácil de um app de limpeza parecer melhor do que é.
    func testTotalNaoContaOMesmoCaminhoDuasVezes() {
        let scope = AnalysisScope(roots: [URL(fileURLWithPath: caches)])
        let duplicated = CleanupCandidate(
            url: URL(fileURLWithPath: "\(caches)/mesmo.bin"),
            category: .applicationCache,
            reason: "Apareceu em duas categorias.",
            confidence: .certain,
            sizeOnDisk: 1_000
        )
        let other = candidate("outro.bin", category: .oldLogs, confidence: .certain, size: 500)

        let result = SmartScanResult(
            groups: [
                CleanupCategoryGroup(category: .applicationCache, candidates: [duplicated]),
                CleanupCategoryGroup(category: .oldLogs, candidates: [duplicated, other])
            ],
            startedAt: Date(),
            finishedAt: Date(),
            progress: ScanProgress(),
            inaccessiblePaths: [],
            scannedRoots: scope.roots
        )

        XCTAssertEqual(result.totalRecoverable, 1_500, "\(caches)/mesmo.bin não pode contar duas vezes")
        XCTAssertEqual(result.totalCandidates, 3, "a contagem de candidatos é outro conceito e não é deduplicada")
    }

    // MARK: - Confiança

    func testOrdenacaoDeConfianca() {
        XCTAssertTrue(Confidence.certain > Confidence.likely)
        XCTAssertTrue(Confidence.likely > Confidence.uncertain)
        XCTAssertFalse(Confidence.uncertain > Confidence.certain)
    }

    // MARK: - Legibilidade de vazios

    /// Um estado vazio bem rotulado vale mais que um zero.
    func testMedicaoIndisponivelCarregaMotivo() {
        let unavailable: MacCareCore.Measurement<CPUUsage> = .unavailable(.noPublicAPI)

        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertNil(unavailable.value)
        XCTAssertEqual(unavailable.unavailableReason, .noPublicAPI)
        XCTAssertFalse(
            UnavailableReason.noPublicAPI.explanation.isEmpty,
            "todo estado indisponível precisa explicar por quê"
        )
    }

    func testMedicaoDisponivelPropagaTransformacao() {
        let memory: MacCareCore.Measurement<MemoryUsage> = .available(
            MemoryUsage(
                physical: 16_000_000_000,
                wired: 1_000_000_000,
                active: 4_000_000_000,
                compressed: 0,
                free: 3_000_000_000,
                available: 8_000_000_000,
                swapUsed: nil
            )
        )
        let bytes: MacCareCore.Measurement<Int64> = memory.map(\.physical)

        XCTAssertEqual(bytes.value, 16_000_000_000)
    }
}
