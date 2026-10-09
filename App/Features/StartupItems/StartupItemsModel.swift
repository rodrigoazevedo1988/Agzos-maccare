import AppKit
import Foundation
import MacCareCore
import Observation

/// ## Estado da tela de inicialização
///
/// ## A restrição que organiza tudo
///
/// O macOS **não** oferece API pública para listar **e alterar** itens de
/// inicialização de terceiros. `SMAppService` só funciona para o próprio
/// aplicativo; para o resto do sistema existem a leitura dos arquivos em
/// `LaunchAgents`/`LaunchDaemons` e a tela "Itens de login" das Configurações.
///
/// Duas consequências diretas, e elas são a tela inteira:
///
/// 1. **Não existe botão de desativar.** `StartupItem.canToggleInApp` é
///    `false` por construção no núcleo, e a interface repete esse `false` em
///    vez de oferecer um controle que não faria nada.
/// 2. **Não existe remoção.** Apagar um `LaunchAgent` ou `LaunchDaemon` para
///    "desativar" seria o oposto de transparência: o usuário pediria uma
///    mudança de comportamento e receberia perda de arquivo. Este módulo não
///    tem caminho de escrita no disco, por construção.
///
/// O que ele faz em vez disso: listar com origem, dizer onde resolver cada
/// item de terceiros e abrir a tela certa das Configurações do Sistema.
@Observable
@MainActor
final class StartupItemsModel {

    enum Phase: Equatable {
        case idle
        case scanning
        case ready
    }

    /// Um grupo dentro de "terceiros" ou "do sistema", por origem do item.
    struct Group: Identifiable {
        let source: StartupItem.Source
        let items: [StartupItem]

        var id: String { source.rawValue }
    }

    /// Um item é de terceiros quando não é do sistema — o que o macOS não
    /// permite ao app alterar. Itens do sistema recebem texto, não botão.
    ///
    /// A separação é feita aqui, no estado, e não na view: qualquer tela que
    /// consuma este modelo recebe as duas listas já divididas e não pode
    /// esquecer a distinção por acidente.
    struct Section: Identifiable {
        let title: String
        let subtitle: String
        let groups: [Group]

        var id: String { title }
    }

    private let environment: AppEnvironment

    private(set) var phase: Phase = .idle
    private(set) var items: [StartupItem] = []
    private(set) var errorMessage: String?
    /// Item cuja instrução está aberta na tela. Guardar o identificador — e não
    /// o item — evita depender da identidade da struct para expandir e recolher.
    private(set) var revealedItemID: String?

    private var scanTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - Carga

    /// Varre `LaunchAgents` e `LaunchDaemons` dos diretórios do sistema e do
    /// usuário. Leitura pura: nada é aberto para escrita em nenhum momento.
    func scan() {
        guard scanTask == nil else { return }

        phase = .scanning
        errorMessage = nil

        let scanner = environment.startupItems
        scanTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> [StartupItem] in
                scanner.scan()
            }.value

            guard let self, !Task.isCancelled else { return }
            self.items = found
            self.phase = .ready
            self.scanTask = nil
        }
    }

    /// Dispensa a mensagem de falha, mantendo a lista como está.
    ///
    /// Falha ao abrir as Configurações não invalida a varredura: o item segue
    /// listado e o usuário pode tentar de novo.
    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Leitura derivada

    var thirdPartySections: [Section] {
        sections(for: items.filter { !$0.isSystemProvided })
    }

    var systemSections: [Section] {
        sections(for: items.filter(\.isSystemProvided))
    }

    var thirdPartyCount: Int { items.filter { !$0.isSystemProvided }.count }
    var systemCount: Int { items.filter(\.isSystemProvided).count }
    var isEmpty: Bool { items.isEmpty }

    private func sections(for list: [StartupItem]) -> [Section] {
        let groups = Dictionary(grouping: list, by: \.source)
            .map { source, entries in
                Group(source: source, items: entries.sorted { lhs, rhs in
                    if lhs.isCurrentlyRunning != rhs.isCurrentlyRunning { return lhs.isCurrentlyRunning }
                    return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
                })
            }
            .sorted { $0.source.rawValue < $1.source.rawValue }

        let isSystem = list.allSatisfy(\.isSystemProvided)
        let count = list.count
        let explanation = isSystem
            ? "O MacCare não altera nem remove itens do sistema. Eles existem para o macOS funcionar."
            : "O macOS não permite que outro aplicativo altere itens de inicialização de terceiros. O MacCare diz onde resolvê-los, em vez de oferecer um botão que não faria nada."

        return [
            Section(
                title: isSystem ? "Itens do macOS" : "Itens de terceiros",
                subtitle: "\(count) \(count == 1 ? "item" : "itens") — \(explanation)",
                groups: groups
            )
        ]
    }

    // MARK: - Orientação

    func isRevealed(_ item: StartupItem) -> Bool {
        revealedItemID == item.id
    }

    func toggleGuidance(for item: StartupItem) {
        revealedItemID = isRevealed(item) ? nil : item.id
    }

    /// URL das Configurações do Sistema para este item, quando existe.
    func settingsURL(for item: StartupItem) -> URL? {
        StartupItemGuidance.settingsURL(for: item)
    }

    /// Abre a tela correta das Configurações do Sistema.
    ///
    /// `NSWorkspace.open` com o esquema `x-apple.systempreferences` é a via
    /// suportada pelo macOS. Como este é o único caminho que o usuário tem para
    /// resolver o item, uma falha aqui precisa ser dita — um clique que não faz
    /// nada é pior do que nenhuma ação.
    func openSettings(for item: StartupItem) {
        guard let url = settingsURL(for: item) else {
            errorMessage = "Não há uma tela de Configurações que resolva \(item.label) diretamente."
            return
        }

        let opened = NSWorkspace.shared.open(url)
        if !opened {
            errorMessage = "Não foi possível abrir as Configurações do Sistema para \(item.label)."
        }
    }

    /// Texto de estado do item.
    ///
    /// `isEnabled == nil` significa "o macOS não informa" — e é assim que
    /// aparece. Tratar `nil` como `false` afirmaria que um item está
    /// desabilitado sem nenhuma evidência, e é exatamente o tipo de erro que
    /// faz um usuário procurar um problema que não existe.
    func stateExplanation(for item: StartupItem) -> String? {
        guard item.isEnabled == nil else { return nil }
        return "O macOS não informa por API pública se este item está habilitado. Ausência de informação não é item desabilitado."
    }

    func guidance(for item: StartupItem) -> String {
        StartupItemGuidance.instruction(for: item)
    }
}
