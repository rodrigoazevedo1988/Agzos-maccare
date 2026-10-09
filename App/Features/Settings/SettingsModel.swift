import Foundation
import MacCareCore
import Observation

/// ## Ajustes
///
/// Poucos ajustes, e todos com consequência visível. A seção mais importante é
/// a de **escopo**: ela é a autorização do usuário para o MacCare olhar
/// qualquer coisa, e por isso mostra os caminhos literais, explica o que cada um
/// é, e permite revogar o que foi concedido a qualquer momento.
///
/// ## Um detalhe de implementação que vale registro
///
/// `AppEnvironment.scope` tem um `didSet` que reconstrói o `PathGuard` e os
/// serviços de limpeza. Propriedades com observadores não são reescritas pela
/// macro `@Observable`, então essa mudança **não** gera por si só uma
/// invalidação de view. Por isso o model mantém uma cópia própria do escopo
/// (`scopeRoots`): é ela que é observada, e é por isso que a lista de pastas
/// realmente muda na tela no instante em que o usuário mexe no interruptor.
@Observable
@MainActor
final class SettingsModel {

    // MARK: - Escopo de análise

    /// Cópia observável do escopo vigente. Ver a nota de classe.
    private(set) var scopeRoots: [URL] = []
    private(set) var scopeIncludesDownloads = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?

    private static let includeDownloadsKey = "com.agzos.MacCare.scope.includeDownloads"

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        refreshScope()

        // A preferência é aplicada de fato na abertura. Sem isso, marcar a opção
        // e reabrir o aplicativo reverteria o escopo em silêncio — e um
        // interruptor que “lembra” visualmente e esquece na prática é pior que
        // um que não existe.
        let stored = UserDefaults.standard.bool(forKey: Self.includeDownloadsKey)
        if stored != scopeIncludesDownloads {
            applyScope(includeDownloads: stored, announce: false)
        }
    }

    /// O interruptor da tela. O valor persistido é a preferência; o valor
    /// vigente é o que o escopo realmente é — e é este que a tela mostra, para
    /// que o interruptor nunca contradiga o que está valendo.
    var includeDownloads: Bool { scopeIncludesDownloads }

    func setIncludeDownloads(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.includeDownloadsKey)
        applyScope(includeDownloads: value, announce: true)
    }

    /// Reconstrói o escopo e o reassina no ambiente.
    ///
    /// Reduzir o escopo revoga de verdade: o `PathGuard` novo é derivado das
    /// raízes novas, e as autorizações antigas deixam de existir. É o
    /// comportamento correto para um interruptor de permissão — revogar nunca
    /// pode depender de alguém lembrar de revogar.
    private func applyScope(includeDownloads: Bool, announce: Bool) {
        let scope = AnalysisScope.standard(includeDownloads: includeDownloads)
        environment.scope = scope
        refreshScope()

        if scope == nil {
            errorMessage = "Nenhuma pasta pôde ser autorizada para análise. O MacCare precisa de ao menos uma pasta existente entre ~/Library/Caches, ~/Library/Logs, ~/.cache e ~/.Trash."
        } else if announce {
            errorMessage = nil
            statusMessage = includeDownloads
                ? "Escopo atualizado: ~/Downloads passou a fazer parte da análise e da limpeza."
                : "Escopo atualizado: ~/Downloads foi removido da análise e da limpeza."
        }
    }

    func refreshScope() {
        scopeRoots = environment.scope?.roots ?? []
        scopeIncludesDownloads = environment.scope?.includeDownloads ?? false
    }

    /// Caminho com `~` no lugar da pasta pessoal.
    ///
    /// Abrevia por legibilidade e por privacidade: uma tela de configuração que
    /// repete `/Users/nome.sobrenome` em quatro linhas não ajuda ninguém a
    /// conferir o que autorizou.
    func abbreviatedPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty else { return url.path }
        return url.path.replacingOccurrences(of: home, with: "~")
    }

    /// Rótulo legível para cada pasta padrão do escopo.
    func description(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.hasSuffix("/Library/Caches") { return "Caches de aplicativos" }
        if path.hasSuffix("/Library/Logs") { return "Registros de sistema do usuário" }
        if path.hasSuffix("/.cache") { return "Cache de ferramentas de linha de comando" }
        if path.hasSuffix("/.Trash") { return "Lixeira" }
        if path.hasSuffix("/Downloads") { return "Downloads (autorizado por você)" }
        return "Pasta autorizada"
    }

    // MARK: - Dados e histórico

    private(set) var historyRecordCount: Int?
    private(set) var historyFileExists = false
    private(set) var isLoadingHistory = false
    private(set) var isClearingHistory = false

    /// Pasta onde o log mora. O arquivo pode ainda não existir: nada é escrito
    /// antes da primeira operação, e dizer "está aqui" para um arquivo que não
    /// está seria uma pequena mentira de configuração.
    var historyLocation: URL { JSONLOperationLog.defaultLocation() }

    var historyLocationText: String { abbreviatedPath(historyLocation) }

    var historyFolderText: String { abbreviatedPath(historyLocation.deletingLastPathComponent()) }

    func loadHistory() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        let url = historyLocation
        historyFileExists = FileManager.default.fileExists(atPath: url.path)

        do {
            historyRecordCount = try await environment.operationLog.all().count
        } catch {
            historyRecordCount = nil
            errorMessage = "Não foi possível ler o histórico: \(error.localizedDescription)"
        }
    }

    /// Apaga o histórico a partir dos Ajustes.
    ///
    /// A tela de Histórico é o caminho principal; esta seção existe para quem
    /// está nos Ajustes e decide apagar. Mesma confirmação, mesma consequência
    /// irreversível, mesma explicação: apagar o registro não desfaz nada.
    func clearHistory() async {
        isClearingHistory = true
        defer { isClearingHistory = false }

        do {
            try await environment.operationLog.clear()
            historyRecordCount = 0
            historyFileExists = false
            errorMessage = nil
            statusMessage = "Histórico apagado. Nenhuma operação já executada foi desfeita por isso."
        } catch {
            errorMessage = "Não foi possível apagar o histórico: \(error.localizedDescription)"
        }
    }

    // MARK: - Sobre

    /// Limitação real do macOS, replicada aqui para não depender de quem lembra
    /// do README.
    struct KnownLimitation: Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String
    }

    static let knownLimitations: [KnownLimitation] = [
        KnownLimitation(
            id: "temperature",
            title: "Temperatura da CPU",
            detail: "Não existe API pública para ler sensores de temperatura. O aplicativo mostra “Indisponível” em vez de estimar um número."
        ),
        KnownLimitation(
            id: "memory-pressure",
            title: "Pressão de memória",
            detail: "Não há API pública para um índice único de pressão. Os componentes de memória são mostrados separadamente, sem um número sintético."
        ),
        KnownLimitation(
            id: "cpu-per-process",
            title: "CPU por processo",
            detail: "O macOS não expõe o consumo de CPU por processo. A lista de processos informa memória; o consumo de CPU por processo aparece como indisponível."
        ),
        KnownLimitation(
            id: "startup-items",
            title: "Itens de inicialização de terceiros",
            detail: "A leitura é possível; a alteração não. Pelo motivo de segurança da Apple, o aplicativo entrega a instrução e abre a tela certa do sistema em vez de desligar algo por conta própria."
        ),
        KnownLimitation(
            id: "full-disk-access",
            title: "Acesso Completo ao Disco",
            detail: "Não é solicitado. O aplicativo funciona sem ele e declara o que não conseguiu ler em vez de estimar."
        ),
        KnownLimitation(
            id: "antivirus",
            title: "Antivírus",
            detail: "Não existe. Não há varredura de malware nem detecção de ameaças. O que existe é verificação de assinatura e de origem dos aplicativos instalados."
        )
    ]

    /// Versão e build. `nil` significa que o `Info.plist` não entregou o valor —
    /// o que aparece como “Indisponível”, nunca como uma versão inventada.
    var appVersion: String? { Self.bundleValue("CFBundleShortVersionString") }
    var appBuild: String? { Self.bundleValue("CFBundleVersion") }

    private static func bundleValue(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        // Build não resolvido aparece literalmente como "$(MARKETING_VERSION)".
        // Exibir isso seria pior do que dizer que o valor não está disponível.
        guard !raw.hasPrefix("$(") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
