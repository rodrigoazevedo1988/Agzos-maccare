import AppKit
import Foundation
import MacCareCore
import Observation

/// ## Estado da tela de aplicativos
///
/// A listagem é o ponto caro deste módulo: `ApplicationCatalog.listApplications()`
/// lê o `Info.plist` de cada bundle e percorre o bundle inteiro para medir o
/// tamanho em disco. Em uma máquina com muitos aplicativos isso leva segundos —
/// tempo suficiente para travar a interface se rodasse no corpo da view.
///
/// Três decisões estruturais:
///
/// 1. A leitura acontece fora do isolate principal, em uma task separada.
/// 2. Existe limite de tempo e limite de exibição. A API do núcleo não é
///    cancelável, então cancelar significa "parar de esperar e descartar o
///    resultado" — e a tela diz exatamente isso, em vez de fingir que a leitura
///    parou.
/// 3. Listagem parcial é declarada. Pastas que não puderam ser lidas e o estouro
///    do tempo limite aparecem como aviso, nunca como lista completa silenciosa.
///
/// ## O que esta tela não faz
///
/// Não verifica atualizações nem afirma que um aplicativo está desatualizado.
/// O PRD §13 proíbe a afirmação: o macOS não expõe um serviço público que
/// associe um bundle instalado à versão mais recente, e a App Store não é
/// consultável por API. Um "há atualização" aqui seria invenção.
@Observable
@MainActor
final class ApplicationsModel {

    // MARK: - Filtros

    /// Onde o aplicativo foi encontrado.
    enum LocationFilter: Hashable, CaseIterable {
        case all
        case location(ApplicationLocation)

        static var allCases: [LocationFilter] {
            [.all] + ApplicationLocation.allCases.map { .location($0) }
        }

        var title: String {
            switch self {
            case .all: return "Todas as localizações"
            case .location(let location): return location.title
            }
        }
    }

    enum SortOrder: String, CaseIterable {
        case nameAscending
        case nameDescending
        case sizeDescending
        case sizeAscending

        var label: String {
            switch self {
            case .nameAscending: return "Nome (A–Z)"
            case .nameDescending: return "Nome (Z–A)"
            case .sizeDescending: return "Maior tamanho"
            case .sizeAscending: return "Menor tamanho"
            }
        }
    }

    /// A listagem não lança: o catálogo devolve uma lista, mesmo vazia. Uma
    /// pasta ilegível vira lista parcial declarada, não erro.
    enum Phase: Equatable {
        case idle
        case listing
        case ready
    }

    // MARK: - Estado

    private let environment: AppEnvironment

    private(set) var phase: Phase = .idle
    private(set) var entries: [ApplicationEntry] = []
    /// Pastas de destino que não puderam ser lidas nesta execução.
    private(set) var unreadableRoots: [String] = []
    /// `true` quando a leitura passou do tempo limite e foi descartada.
    private(set) var exceededTimeLimit = false
    private(set) var lastDuration: TimeInterval = 0
    private(set) var errorMessage: String?

    var searchText: String = ""
    var locationFilter: LocationFilter = .all
    var sortOrder: SortOrder = .nameAscending

    /// Aplicativo escolhido para desinstalação, ou `nil` quando a folha está
    /// fechada. `ApplicationEntry` é `Identifiable`, o que permite
    /// `.sheet(item:)` sem um identificador artificial.
    var appForUninstall: ApplicationEntry?

    private var loadTask: Task<Void, Never>?

    /// Tempo máximo de espera pela listagem antes de a tela avisar que algo
    /// está demorando. Não cancela a leitura — apenas a torna visível.
    static let timeLimit: TimeInterval = 20
    /// Limite de itens exibidos. Acima disso a lista é parcial **na tela**, e a
    /// tela diz isso; nada é descartado silenciosamente.
    static let displayLimit = 400

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - Carga

    /// Carrega o catálogo.
    ///
    /// Chamada em `.task` na primeira exibição da tela. Uma segunda chamada
    /// enquanto a leitura está em andamento é ignorada, para não acumular
    /// varreduras de disco.
    func load(force: Bool = false) {
        guard loadTask == nil else { return }
        if !force, !entries.isEmpty { return }

        phase = .listing
        errorMessage = nil
        exceededTimeLimit = false
        unreadableRoots = []

        let environment = self.environment
        let deadline = Self.timeLimit

        loadTask = Task { [weak self] in
            // Relógio do limite. Não interrompe a leitura: serve para o usuário
            // saber que o mac está demorando, em vez de encarar um spinner
            // mudo.
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(deadline))
                guard !Task.isCancelled else { return }
                self?.exceededTimeLimit = true
            }

            let catalog = environment.applications
            let started = Date()
            let outcome = await Task.detached(priority: .userInitiated) { () -> LoadOutcome in
                let entries = catalog.listApplications(includeSizes: true)
                let unreadable = ApplicationCatalog.defaultRoots
                    .filter { !FileManager.default.isReadableFile(atPath: $0.url.path) }
                    .map(\.url.path)
                return LoadOutcome(entries: entries, unreadableRoots: unreadable, elapsed: Date().timeIntervalSince(started))
            }.value

            watchdog.cancel()

            guard let self, !Task.isCancelled else { return }
            self.entries = outcome.entries
            self.unreadableRoots = outcome.unreadableRoots
            self.lastDuration = outcome.elapsed
            self.exceededTimeLimit = false
            self.phase = .ready
            self.loadTask = nil
        }
    }

    /// Recusa a leitura pendente e descarta o resultado quando ela chegar.
    ///
    /// A API do núcleo não aceita cancelamento: a leitura em disco continua até
    /// terminar sozinha. O que este método garante é que o resultado não entre
    /// na tela depois do pedido de cancelamento.
    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        if phase == .listing {
            phase = entries.isEmpty ? .idle : .ready
        }
    }

    /// Nova leitura após uma desinstalação.
    ///
    /// A folha de desinstalação já foi fechada e o aplicativo provavelmente
    /// não existe mais; sem esta recarga a lista mostraria um item fantasma
    /// até a próxima atualização manual.
    func reloadAfterRemoval() {
        load(force: true)
    }

    /// Resultado interno da leitura, construído fora do isolate principal.
    private struct LoadOutcome: Sendable {
        let entries: [ApplicationEntry]
        let unreadableRoots: [String]
        let elapsed: TimeInterval
    }

    // MARK: - Leitura derivada

    var appleApps: [ApplicationEntry] { appleEntries(entries) }
    var thirdPartyApps: [ApplicationEntry] { thirdPartyEntries(entries) }

    var isEmpty: Bool { entries.isEmpty }

    /// Quantos aplicativos **foram** encontrados, antes de qualquer filtro.
    var totalCount: Int { entries.count }

    /// Quantos passam pelos filtros atuais.
    var visibleCount: Int { appleApps.count + thirdPartyApps.count }

    /// `true` quando a lista exibida foi truncada pelo limite de exibição.
    var isDisplayTruncated: Bool { entries.count > Self.displayLimit }

    /// Aviso único sobre parcialidade da listagem, ou `nil` quando a listagem
    /// foi completa. A tela prefere um aviso a uma lista que parece total e
    /// não é.
    var partialListingNotice: String? {
        var reasons: [String] = []
        if exceededTimeLimit {
            reasons.append("a leitura passou de \(Int(Self.timeLimit)) segundos e ainda não terminou")
        }
        if !unreadableRoots.isEmpty {
            let roots = unreadableRoots.map { "`\($0)`" }.joined(separator: ", ")
            reasons.append("as pastas \(roots) não puderam ser lidas")
        }
        if isDisplayTruncated {
            reasons.append(
                "a tela exibe os \(Self.displayLimit) maiores de \(entries.count) encontrados, ordenados por \(sortOrder.label.lowercased())"
            )
        }
        guard !reasons.isEmpty else { return nil }
        return "Esta listagem pode estar incompleta: " + reasons.joined(separator: "; ") + "."
    }

    // MARK: - Ações

    /// Abre o aplicativo pelo Launch Services.
    ///
    /// `openApplication` é a API correta: o macOS é quem decide se o bundle é
    /// executável e quem resolve o registro. Abrir o executável com `Process`
    /// seria montar uma alternativa menos confiável e fora das regras deste
    /// projeto.
    func launch(_ entry: ApplicationEntry) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                self.errorMessage = error.map {
                    "Não foi possível abrir \(entry.name). \($0.localizedDescription)"
                }
            }
        }
    }

    /// Seleciona o aplicativo no Finder.
    @discardableResult
    func revealInFinder(_ entry: ApplicationEntry) -> Bool {
        // `activateFileViewerSelecting` não devolve resultado; a única falha
        // verificável antes da chamada é o item não existir mais.
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            errorMessage = "Não foi possível selecionar \(entry.name) no Finder."
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        return true
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Filtro e ordenação

    /// Aplica busca e filtro de localização.
    ///
    /// A busca cobre nome, identificador do bundle e caminho: o usuário que
    /// lembra o identificador de um app o encontra, e quem lembra da pasta
    /// também.
    private func filtered(_ list: [ApplicationEntry]) -> [ApplicationEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = locationFilter

        return list.filter { entry in
            switch location {
            case .all: break
            case .location(let selected): guard entry.location == selected else { return false }
            }
            guard !query.isEmpty else { return true }
            return entry.name.localizedCaseInsensitiveContains(query)
                || (entry.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
                || entry.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    private func sorted(_ list: [ApplicationEntry]) -> [ApplicationEntry] {
        let ordered = list.sorted { lhs, rhs in
            switch sortOrder {
            case .nameAscending:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .nameDescending:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
            case .sizeDescending:
                return Self.isLarger(lhs, than: rhs)
            case .sizeAscending:
                return Self.isLarger(rhs, than: lhs)
            }
        }

        guard isDisplayTruncated else { return ordered }
        return Array(ordered.prefix(Self.displayLimit))
    }

    /// Ordem de tamanho com uma regra explícita: **item sem tamanho medido não
    /// é item de tamanho zero**. Sem isso, um app dentro de uma pasta
    /// inacessível pareceria o menor de todos.
    private static func isLarger(_ lhs: ApplicationEntry, than rhs: ApplicationEntry) -> Bool {
        switch (lhs.sizeOnDisk, rhs.sizeOnDisk) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            // Empate em tamanho (ou nenhum medido): desempate por nome, para a
            // ordem ser estável entre recargas.
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func appleEntries(_ list: [ApplicationEntry]) -> [ApplicationEntry] {
        sorted(filtered(list.filter(\.isAppleProvided)))
    }

    private func thirdPartyEntries(_ list: [ApplicationEntry]) -> [ApplicationEntry] {
        sorted(filtered(list.filter { !$0.isAppleProvided }))
    }
}
