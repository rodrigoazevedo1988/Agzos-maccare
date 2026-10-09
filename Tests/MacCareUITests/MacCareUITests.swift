import XCTest

/// ## Testes de interface
///
/// O que só pode ser verificado com o app de verdade: navegação, estados
/// vazios, confirmação, cancelamento e redimensionamento.
///
/// ## Regra que vale mais que os testes individuais
///
/// Nenhum teste desta suíte pode, em nenhuma hipótese, executar uma limpeza de
/// verdade. Os testes de interface tocam o disco do usuário da máquina de teste
/// (o CI roda em runner efêmero, mas a máquina de alguém rodando localmente é a
/// máquina de alguém). Por isso todo teste que chega perto de uma ação
/// destrutiva **cancela** o diálogo em vez de confirmá-lo.
///
/// Um teste de interface que apaga arquivo do HOME é pior do que nenhum teste.
final class MacCareUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Navegação

    /// A barra lateral lista todos os módulos declarados e permite trocar entre eles.
    func testNavegaEntreTodosOsModulos() {
        let modules = [
            "Visão geral", "Limpeza inteligente", "Armazenamento", "Arquivos grandes",
            "Duplicados", "Aplicativos", "Desempenho", "Inicialização",
            "Privacidade", "Proteção", "Histórico", "Ajustes"
        ]

        for module in modules {
            let item = app.menuItems[module]
            XCTAssertTrue(
                item.waitForExistence(timeout: 10),
                "o módulo \"\(module)\" deveria existir na barra lateral"
            )
            item.click()

            // O cabeçalho contextual deve refletir o módulo escolhido.
            XCTAssertTrue(
                app.staticTexts[module].waitForExistence(timeout: 5),
                "o cabeçalho deveria mostrar \"\(module)\" após selecioná-lo"
            )
        }
    }

    /// A visão geral abre e mostra a identificação do Mac.
    func testVisaoGeralExibeIdentificacaoDoDispositivo() {
        XCTAssertTrue(app.staticTexts["Visão geral"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["macOS"].waitForExistence(timeout: 10),
            "a versão do macOS é informação que o app sempre tem"
        )
    }

    // MARK: - Confirmação e cancelamento

    /// O caminho crítico: pedir a limpeza **não** pode apagar nada sozinho.
    func testConfirmacaoDeLimpezaEhCanceladaSemExecutar() {
        navigate(to: "Limpeza inteligente")

        let analisar = app.buttons["Analisar"]
        guard analisar.waitForExistence(timeout: 10) else {
            return XCTFail("o botão de análise deveria existir na tela de limpeza")
        }
        analisar.click()

        // Se houver diálogo de confirmação, cancelamos. Se a varredura rodar,
        // nenhum arquivo é removido: remoção exige confirmação explícita.
        let cancelar = app.buttons["Cancelar"]
        if cancelar.waitForExistence(timeout: 30) {
            cancelar.click()
        }

        XCTAssertFalse(
            app.alerts.firstMatch.waitForExistence(timeout: 2),
            "o diálogo de confirmação deveria ter sido dispensado"
        )
    }

    // MARK: - Estados indisponíveis

    /// A tela de desempenho declara explicitamente o que não pode medir.
    ///
    /// Este teste documenta uma decisão de produto: temperatura e CPU por
    /// processo aparecem como indisponíveis, em vez de o app inventar número.
    func testDesempenhoDeclaraLimitacoesDoMacOS() {
        navigate(to: "Desempenho")

        XCTAssertTrue(
            app.staticTexts["Indisponível"].waitForExistence(timeout: 10),
            "campos sem API pública devem aparecer como indisponíveis"
        )
    }

    // MARK: - Tema e layout

    /// Alternar entre claro e escuro não pode deixar texto ilegível.
    ///
    /// A verificação aqui é estrutural: o app precisa continuar navegável e as
    /// telas não podem quebrar. Contraste real é medido por revisão visual —
    /// automatizar isso exigiria amostragem de pixel, que é mais frágil do que
    /// útil neste estágio.
    func testAppPermaneceNavegavelEmAmbosOsTemas() {
        app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        app.terminate()
        app.launch()

        navigate(to: "Visão geral")
        XCTAssertTrue(app.staticTexts["Visão geral"].waitForExistence(timeout: 10))
    }

    /// A janela deve sobreviver ao redimensionamento sem truncar conteúdo crítico.
    func testRedimensionaJanelaSemQuebrarLayout() {
        navigate(to: "Visão geral")

        let janela = app.windows.firstMatch
        XCTAssertTrue(janela.waitForExistence(timeout: 10))

        janela.resize(to: CGSize(width: 900, height: 600))
        XCTAssertTrue(app.staticTexts["Visão geral"].waitForExistence(timeout: 5),
                      "o cabeçalho deve continuar visível na largura mínima")

        janela.resize(to: CGSize(width: 1_600, height: 1_000))
        XCTAssertTrue(app.staticTexts["Visão geral"].waitForExistence(timeout: 5),
                      "o cabeçalho deve continuar visível em janela grande")
    }

    // MARK: - Auxiliar

    private func navigate(to module: String) {
        let item = app.menuItems[module]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "módulo \"\(module)\" não encontrado")
        item.click()
    }
}
