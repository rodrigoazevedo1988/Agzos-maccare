import AppKit
import Foundation
import MacCareCore
import Observation

/// ## Privacidade: orientação, não varredura
///
/// A tentação natural desta tela é listar "quais aplicativos têm acesso à sua
/// câmera". Isso é impossível: o macOS guarda a tabela de permissões em um
/// banco privado (`TCC.db`) e **não expõe API pública** para consultá-la nem
/// para revogar entradas de outros aplicativos.
///
/// Como o PRD §17 proíbe afirmar capacidades que não existem, esta tela foi
/// desenhada na direção oposta da falsa potência: ela diz o que não é possível
/// fazer, entrega o **caminho exato** até a tela do sistema onde a revisão
/// acontece e só então oferece a limpeza que o app de fato consegue executar —
/// que é minúscula e explicitamente opcional.
///
/// Duas regras estruturam o arquivo:
///
/// 1. `NSWorkspace.open` só **abre** telas. Nenhum caminho altera, concede ou
///    revoga permissão, porque o app não tem como fazer isso.
/// 2. A limpeza opcional nunca é "o que foi encontrado". Cada item nasce
///    desmarcado e só entra no plano depois de marcação explícita, um a um.
@Observable
@MainActor
final class PrivacyModel {

    // MARK: - Dependência

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - Tópicos de revisão no macOS

    /// Destino do sistema. `url` é um *deep link* de abertura de tela, nunca um
    /// comando: ele leva o usuário ao lugar certo e para.
    struct SystemLink: Identifiable, Hashable, Sendable {
        let id: String
        let label: String
        let url: URL?
    }

    /// Um assunto que vale revisar, com explicação, caminho manual e o botão
    /// que abre a tela correspondente.
    struct ReviewTopic: Identifiable, Sendable {
        let id: String
        let title: String
        let symbolName: String
        /// O que o MacCare sabe e o que não sabe sobre este assunto.
        let explanation: String
        /// Caminho escrito, para quando o botão não abrir nada.
        let manualPath: String
        let links: [SystemLink]
    }

    /// Lista estática: os endereços internos do macOS não mudam durante a
    /// sessão e não dependem do estado do Mac.
    var topics: [ReviewTopic] { ReviewTopic.all }

    /// Abre uma tela do sistema.
    ///
    /// O retorno de `NSWorkspace.open` é verificado de propósito: um destino
    /// interno pode deixar de existir em uma versão futura do macOS, e um botão
    /// que falha em silêncio seria pior que nenhum botão.
    func open(_ link: SystemLink) {
        guard let url = link.url else {
            errorMessage = "Esta tela não está disponível nesta versão do macOS. Use o caminho manual descrito acima."
            return
        }
        if !NSWorkspace.shared.open(url) {
            errorMessage = "O macOS não abriu “\(link.label)”. O caminho manual descrito acima continua válido."
        }
    }

    /// Abre a tela de itens de login, onde o usuário desativa itens de
    /// inicialização de terceiros — algo que o macOS não permite fazer por API.
    ///
    /// O endereço é o mesmo devolvido por `StartupItemGuidance.settingsURL(for:)`
    /// para itens de terceiros. Ele aparece aqui literal porque este botão é do
    /// cabeçalho da seção e não pertence a um item específico; a instrução
    /// textual de cada item, essa sim, vem do próprio guia do núcleo.
    func openLoginItemsSettings() {
        open(SystemLink(
            id: "login-items",
            label: "Itens de login e extensões",
            url: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        ))
    }

    /// Abre a tela do sistema que resolve um item específico.
    ///
    /// A URL vem de `StartupItemGuidance`, que devolve `nil` para itens do
    /// sistema — e aí o botão não aparece, porque um botão que não faz nada é
    /// pior do que a frase que explica o porquê.
    func openSettings(for item: StartupItem) {
        open(SystemLink(id: item.id, label: "Abrir no sistema", url: StartupItemGuidance.settingsURL(for: item)))
    }

    // MARK: - Itens de inicialização (somente leitura)

    private(set) var startupItems: [StartupItem] = []
    private(set) var isLoadingStartupItems = false

    var thirdPartyStartupItems: [StartupItem] { startupItems.filter { !$0.isSystemProvided } }
    var systemStartupItemCount: Int { startupItems.count - thirdPartyStartupItems.count }

    /// Lê os itens de inicialização.
    ///
    /// A leitura de plists toca o disco, então sai do MainActor. O `scanner` é
    /// `Sendable`: a instância é capturada aqui e usada dentro da tarefa.
    func loadStartupItems() async {
        guard startupItems.isEmpty else { return }
        isLoadingStartupItems = true
        defer { isLoadingStartupItems = false }

        let scanner = environment.startupItems
        startupItems = await Task.detached(priority: .utility) { scanner.scan() }.value
    }

    // MARK: - Cache de navegadores (limpeza opcional)

    /// Uma pasta de cache conhecida, com o que sai dela e o que acontece depois.
    ///
    /// O alvo é **sempre um cache**, nunca histórico, cookies, senhas,
    /// preenchimentos ou favoritos. É a diferença entre uma limpeza honesta e
    /// uma limpeza que apaga a vida da pessoa.
    struct BrowserCacheTarget: Identifiable, Hashable, Sendable {
        let id: String
        let browserName: String
        let url: URL
        /// Caminho exibido com `~` no lugar da pasta do usuário.
        let displayPath: String
        /// O que exatamente será movido para a Lixeira.
        let whatIsRemoved: String
        /// O que o usuário precisa saber antes de confirmar.
        let consequence: String
        /// `nil` significa "não foi possível medir" — nunca zero.
        var sizeOnDisk: Int64?

        static let known: [BrowserCacheTarget] = {
            let home = FileManager.default.homeDirectoryForCurrentUser

            func target(
                id: String,
                browser: String,
                relative: String,
                whatIsRemoved: String
            ) -> BrowserCacheTarget {
                let url = home.appendingPathComponent(relative, isDirectory: true)
                return BrowserCacheTarget(
                    id: id,
                    browserName: browser,
                    url: url,
                    displayPath: "~/" + relative,
                    whatIsRemoved: whatIsRemoved,
                    consequence: "Feche o navegador antes de continuar. O cache é recriado na próxima navegação, e a primeira abertura pode demorar um pouco mais.",
                    sizeOnDisk: nil
                )
            }

            let caches = "apenas arquivos de cache (imagens, scripts e respostas guardados para carregar as páginas mais rápido)"
            let container = "o cache do navegador dentro do seu contêiner de dados"

            return [
                target(
                    id: "safari",
                    browser: "Safari",
                    relative: "Library/Caches/com.apple.Safari",
                    whatIsRemoved: caches
                ),
                target(
                    id: "safari-container",
                    browser: "Safari (contêiner)",
                    relative: "Library/Containers/com.apple.Safari/Data/Library/Caches",
                    whatIsRemoved: "\(container). Sem Acesso Completo ao Disco esta pasta normalmente não pode ser lida, e o tamanho dela aparece como “não foi possível medir”"
                ),
                target(
                    id: "chrome",
                    browser: "Google Chrome",
                    relative: "Library/Caches/Google/Chrome",
                    whatIsRemoved: caches
                ),
                target(
                    id: "edge",
                    browser: "Microsoft Edge",
                    relative: "Library/Caches/Microsoft Edge",
                    whatIsRemoved: caches
                ),
                target(
                    id: "brave",
                    browser: "Brave",
                    relative: "Library/Caches/BraveSoftware",
                    whatIsRemoved: caches
                ),
                target(
                    id: "firefox",
                    browser: "Firefox",
                    relative: "Library/Caches/Firefox",
                    whatIsRemoved: "\(caches) dos perfis do Firefox"
                )
            ]
        }()
    }

    /// Resultado de uma limpeza, reduzido ao que a tela precisa mostrar.
    ///
    /// Guardar o relatório inteiro aqui não acrescentaria nada: a contabilidade
    /// de espaço é o único dado que sobrevive à mudança de tela, e é ela que
    /// precisa continuar honesta.
    struct CleanupOutcome: Sendable {
        let browserNames: [String]
        let summary: String
        let identified: Int64
        let selected: Int64
        let releasedConfirmed: Int64
        let releasedUnconfirmed: Int64
        let failedItems: Int

        init(report: RemovalReport, browserNames: [String]) {
            self.browserNames = browserNames
            self.summary = report.summary
            self.identified = report.accounting.identified
            self.selected = report.accounting.selected
            self.releasedConfirmed = report.accounting.releasedConfirmed
            self.releasedUnconfirmed = report.accounting.releasedUnconfirmed
            self.failedItems = report.accounting.failedItems
        }
    }

    private(set) var browserCaches: [BrowserCacheTarget] = []
    private(set) var isMeasuringCaches = false
    private(set) var isCleaningCaches = false
    private(set) var cleanupOutcome: CleanupOutcome?

    /// Seleção do usuário. Começa vazia **sempre** — nada entra no plano por
    /// estar "ali".
    var selectedCacheIDs: Set<String> = []

    var errorMessage: String?

    private var measuringTask: Task<Void, Never>?

    var selectedCacheCount: Int { selectedCacheIDs.count }

    func isSelected(_ target: BrowserCacheTarget) -> Bool {
        selectedCacheIDs.contains(target.id)
    }

    func setSelected(_ target: BrowserCacheTarget, _ selected: Bool) {
        if selected {
            selectedCacheIDs.insert(target.id)
        } else {
            selectedCacheIDs.remove(target.id)
        }
    }

    func selectAllCaches() {
        selectedCacheIDs = Set(browserCaches.map(\.id))
    }

    func clearSelection() {
        selectedCacheIDs = []
    }

    // MARK: - Medição

    /// Procura as pastas de cache conhecidas e mede o conteúdo de cada uma.
    ///
    /// A medição acontece fora do MainActor, pasta por pasta. Isso não é
    /// otimização: é o que torna o botão "Parar" verdadeiramente eficaz — a
    /// tarefa observa o cancelamento entre pastas e interrompe a varredura no
    /// próximo item, em vez de apenas esconder um resultado que continuaria
    /// sendo calculado.
    func startMeasuringCaches() {
        measuringTask?.cancel()
        measuringTask = Task { [weak self] in
            await self?.measureBrowserCaches()
        }
    }

    func cancelMeasuringCaches() {
        measuringTask?.cancel()
    }

    private func measureBrowserCaches() async {
        isMeasuringCaches = true
        errorMessage = nil
        defer { isMeasuringCaches = false }

        // A verificação de existência acontece aqui, e não na tarefa destacada:
        // são seis chamadas de sistema, e manter a lista de alvos no MainActor
        // evita depender de o tipo aninhado estar ou não isolado fora dele.
        let existing = BrowserCacheTarget.known.filter { FileManager.default.fileExists(atPath: $0.url.path) }

        var measured: [BrowserCacheTarget] = []
        for target in existing {
            if Task.isCancelled { break }

            let size = await Task.detached(priority: .utility) {
                FileSizeMeasurer.directorySize(of: target.url, fs: LiveFileSystem())
            }.value

            var updated = target
            updated.sizeOnDisk = size
            measured.append(updated)
        }

        if Task.isCancelled {
            errorMessage = "Medição interrompida. As pastas já medidas continuam na lista; as restantes serão incluídas na próxima tentativa."
            browserCaches = measured
            selectedCacheIDs = selectedCacheIDs.intersection(Set(measured.map(\.id)))
            return
        }

        browserCaches = measured
        selectedCacheIDs = selectedCacheIDs.intersection(Set(measured.map(\.id)))
        if cleanupOutcome != nil { cleanupOutcome = nil }
    }

    // MARK: - Limpeza

    /// Executa a limpeza dos caches **explicitamente marcados**.
    ///
    /// A seleção vira candidatos comuns e passa por
    /// `AppEnvironment.performCleanup`, que revalida cada caminho no
    /// `PathGuard` no momento da execução. A tela não tem como contornar essa
    /// porta, e é exatamente por isso que a seleção é explícita aqui: a
    /// autorização do usuário acontece uma vez e é conferida de novo no
    /// instante da remoção.
    func cleanSelectedCaches() async {
        let selected = browserCaches.filter { selectedCacheIDs.contains($0.id) }

        guard !selected.isEmpty else {
            errorMessage = "Nenhum cache foi selecionado. Marque ao menos um item para continuar."
            return
        }

        isCleaningCaches = true
        errorMessage = nil
        defer { isCleaningCaches = false }

        let candidates = selected.map { target in
            CleanupCandidate(
                url: target.url,
                category: .applicationCache,
                reason: "Cache do \(target.browserName) em pasta de regeneração automática: \(target.whatIsRemoved).",
                confidence: .certain,
                sizeOnDisk: target.sizeOnDisk,
                isDirectory: true,
                consequence: target.consequence
            )
        }

        do {
            let result = try await environment.performCleanup(
                candidates: candidates,
                strategy: .moveToTrash,
                kind: .smartCleanup
            )
            cleanupOutcome = CleanupOutcome(
                report: result.report,
                browserNames: selected.map(\.browserName)
            )
            selectedCacheIDs = []
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

// MARK: - Conteúdo dos tópicos

extension PrivacyModel.ReviewTopic {

    static let all: [PrivacyModel.ReviewTopic] = [
        PrivacyModel.ReviewTopic(
            id: "camera-microphone",
            title: "Câmera e microfone",
            symbolName: "video",
            explanation: """
            O macOS registra e revoga as autorizações de câmera e microfone por \
            aplicativo, mas não oferece nenhuma API pública que permita a um \
            terceiro ler essa tabela. Por isso o MacCare não mostra uma lista de \
            aplicativos com câmera ou microfone ativos: qualquer lista aqui seria \
            inventada. O que existe são as permissões que o próprio MacCare pede — \
            e ele não pede nenhuma dessas duas.
            """,
            manualPath: "Ajustes do Sistema › Privacidade e Segurança › Câmera, e na mesma tela › Microfone",
            links: [
                PrivacyModel.SystemLink(
                    id: "camera",
                    label: "Abrir câmera",
                    url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
                ),
                PrivacyModel.SystemLink(
                    id: "microphone",
                    label: "Abrir microfone",
                    url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                )
            ]
        ),
        PrivacyModel.ReviewTopic(
            id: "files-and-folders",
            title: "Arquivos e pastas",
            symbolName: "folder",
            explanation: """
            Aplicativos podem pedir acesso a pastas específicas — Downloads, \
            Área de Trabalho, Documentos. A lista completa pertence ao macOS e só \
            pode ser vista e alterada na tela de Configurações. Revise qual \
            aplicativo tem acesso a qual pasta: é a permissão mais concedida \
            sem muita leitura e a que mais expõe documentos.
            """,
            manualPath: "Ajustes do Sistema › Privacidade e Segurança › Arquivos e pastas",
            links: [
                PrivacyModel.SystemLink(
                    id: "files",
                    label: "Abrir Arquivos e pastas",
                    url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
                )
            ]
        ),
        PrivacyModel.ReviewTopic(
            id: "accessibility-automation",
            title: "Acessibilidade e automação",
            symbolName: "accessibility",
            explanation: """
            Acessibilidade permite a um aplicativo ler e controlar a interface de \
            outros; automação permite enviar eventos a outros aplicativos. São duas \
            permissões amplas, usadas de forma legítima por acessibilidade real, e \
            por isso merecem uma leitura periódica da lista. O macOS não permite \
            que o MacCare leia essa tabela, apenas que ele indique onde ela está.
            """,
            manualPath: "Ajustes do Sistema › Privacidade e Segurança › Acessibilidade, e na mesma tela › Automação",
            links: [
                PrivacyModel.SystemLink(
                    id: "accessibility",
                    label: "Abrir Acessibilidade",
                    url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                ),
                PrivacyModel.SystemLink(
                    id: "automation",
                    label: "Abrir Automação",
                    url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                )
            ]
        ),
        PrivacyModel.ReviewTopic(
            id: "full-disk-access",
            title: "Acesso Completo ao Disco",
            symbolName: "lock.shield",
            explanation: """
            Acesso Completo ao Disco é a permissão mais ampla que existe, e o \
            MacCare não a solicita — nem pede que você conceda. Ele funciona sem \
            ela: analisa apenas o que o macOS já autoriza e declara explicitamente \
            o que ficou inacessível, em vez de estimar por baixo dos panos. Se você \
            já concedeu acesso a outro aplicativo e não lembra qual é, esta é a \
            tela certa.
            """,
            manualPath: "Ajustes do Sistema › Privabilidade e Segurança › Acesso Completo ao Disco",
            links: [
                PrivacyModel.SystemLink(
                    id: "full-disk",
                    label: "Abrir Acesso Completo ao Disco",
                    url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                )
            ]
        ),
        PrivacyModel.ReviewTopic(
            id: "lock-screen",
            title: "Tela de bloqueio",
            symbolName: "lock",
            explanation: """
            Login automático, senha de login e o tempo até bloquear depois de uma \
            pausa determinam por quanto tempo o Mac fica aberto para quem estiver \
            perto dele. Vale conferir se a senha existe, se o bloqueio automático \
            está ativo e se o login automático está desligado. O MacCare não altera \
            nada nesta tela: a decisão é sua e a mudança é feita por você, no \
            sistema.
            """,
            manualPath: "Ajustes do Sistema › Tela de bloqueio",
            links: [
                PrivacyModel.SystemLink(
                    id: "lock-screen",
                    label: "Abrir Tela de bloqueio",
                    url: URL(string: "x-apple.systempreferences:com.apple.LockScreen-Settings.extension")
                )
            ]
        ),
        PrivacyModel.ReviewTopic(
            id: "siri-dictation",
            title: "Siri e ditado",
            symbolName: "waveform",
            explanation: """
            Siri pode ouvir o microfone, responder o que aparece na tela e enviar \
            parte dessas informações aos servidores da Apple quando você usa \
            funções como "E aí, Siri" e compartilhamento de tela em voz alta. Vale \
            revisar quem pode acionar esses recursos por voz sem que você precise \
            tocar no teclado. O MacCare não acessa Siri nem ditado.
            """,
            manualPath: "Ajustes do Sistema › Siri e Dictado",
            links: [
                PrivacyModel.SystemLink(
                    id: "siri",
                    label: "Abrir Siri e ditado",
                    url: URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
                )
            ]
        )
    ]
}
