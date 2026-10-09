import Foundation
import MacCareCore
import Observation

/// ## Estado da tela de armazenamento
///
/// A tela responde a "onde o espaço está indo?" — e a honestidade da resposta é
/// o ponto.
///
/// Três grandias precisam permanecer separadas, porque misturá-las produz
/// números que não correspondem a nada que o usuário possa medir no Finder:
///
/// - **Tamanho ocupado** (`StorageNode.sizeOnDisk`): bytes efetivamente
///   alocados, que diferem do tamanho lógico por causa de blocos de contêiner
///   e arquivos esparsos.
/// - **Analisado e inacessível**: o que o MacCare conseguiu ler e o que o
///   macOS não autorizou. `StorageNode.isPartial` marca a diferença, e os
///   totais carregam esse aviso até a interface.
/// - **Estimativa**: nós parciais são estimativas, não medidas. Um total
///   estimado é útil — desde que seja rotulado como tal.
@Observable
@MainActor
final class StorageAnalyzerModel {

    /// ## Fotografia mínima do volume
    ///
    /// Deliberadamente menor que `SystemSnapshot`. Esta tela precisa apenas da
    /// ocupação do volume, e coletar CPU, bateria e a lista de processos para
    /// desenhar barras seria custo sem uso. O `Measurement` viaja junto para
    /// que uma leitura indisponível continue visível como tal.
    struct VolumeSnapshot: Sendable {
        let capturedAt: Date
        let volume: Measurement<VolumeUsage>
    }

    /// Item adaptável para o `OutlineGroup`, que exige a árvore em forma de
    /// coleção de elementos com filhos opcionais.
    ///
    /// `parentSize` viaja junto com o nó porque o `OutlineGroup` entrega cada
    /// elemento sozinho: sem o total do pai, a barra de um item seria sempre
    /// 100% e a leitura relativa — a que interessa — se perderia.
    struct TreeItem: Identifiable {
        let node: StorageNode
        let parentSize: Int64

        var id: String { node.id }

        init(node: StorageNode, parentSize: Int64) {
            self.node = node
            self.parentSize = parentSize
        }

        var children: [TreeItem]? {
            node.children.isEmpty
                ? nil
                : node.children.map { TreeItem(node: $0, parentSize: node.sizeOnDisk) }
        }
    }

    enum Depth: Int, CaseIterable, Identifiable {
        case one = 1
        case two = 2
        case three = 3
        case four = 4

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .one: return "Somente o nível atual"
            case .two: return "Dois níveis"
            case .three: return "Três níveis"
            case .four: return "Quatro níveis"
            }
        }
    }

    // MARK: - Controles

    var root: URL? = FileManager.default.homeDirectoryForCurrentUser
    var isChoosingFolder = false
    var depth: Depth = .three

    // MARK: - Estado

    private(set) var snapshot: VolumeSnapshot?
    private(set) var tree: StorageNode?
    private(set) var isLoadingTree = false
    private(set) var isRefreshingVolume = false
    var errorMessage: String?

    @ObservationIgnored private let metrics: HostMetricsCollector
    @ObservationIgnored private var treeTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?

    init() {
        self.metrics = HostMetricsCollector()
    }

    var canAnalyze: Bool { root != nil && !isLoadingTree }

    // MARK: - Volume

    /// Coleta a ocupação do volume.
    ///
    /// Só é chamada por ação explícita do usuário. A tela **não** recebe
    /// `AppModel`, então não reaproveita o `snapshot` que o `RootView` coleta
    /// na abertura; o que ela evita é a coleta dupla dentro da própria tela,
    /// coletando apenas o campo que usa.
    func refreshVolume() {
        guard !isRefreshingVolume else { return }
        isRefreshingVolume = true

        let collector = metrics
        volumeTask = Task { [weak self] in
            let measurement = await Task.detached(priority: .utility) {
                collector.volumeUsage()
            }.value
            self?.snapshot = VolumeSnapshot(capturedAt: Date(), volume: measurement)
            self?.isRefreshingVolume = false
            self?.volumeTask = nil
        }
    }

    // MARK: - Árvore

    func loadTree(environment: AppEnvironment) {
        guard let root, !isLoadingTree else { return }

        treeTask?.cancel()
        isLoadingTree = true
        errorMessage = nil
        tree = nil

        let scanner = environment.scanner
        let maxDepth = depth.rawValue
        let limits = environment.scope?.limits ?? .thorough

        treeTask = Task { [weak self] in
            let node = await scanner.buildStorageTree(
                root: root,
                maxDepth: maxDepth,
                limits: limits
            )
            guard !Task.isCancelled else {
                self?.isLoadingTree = false
                self?.treeTask = nil
                return
            }
            self?.tree = node
            self?.isLoadingTree = false
            self?.treeTask = nil
        }
    }

    func cancelTreeLoading() {
        guard isLoadingTree else { return }
        treeTask?.cancel()
        treeTask = nil
        isLoadingTree = false
    }

    // MARK: - Totais e honestidade

    /// Bytes medidos na árvore. Nenhum ajuste é aplicado: o valor exibido é o
    /// que o scanner produziu.
    var analyzedSize: Int64 { tree?.sizeOnDisk ?? 0 }

    /// Nós cujo tamanho é estimativa, porque parte da árvore não pôde ser lida.
    var partialNodeCount: Int { countPartial(in: tree) }

    private func countPartial(in node: StorageNode?) -> Int {
        guard let node else { return 0 }
        let own = node.isPartial ? 1 : 0
        return node.children.reduce(own) { $0 + countPartial(in: $1) }
    }

    var topLevelItems: [TreeItem] {
        guard let tree else { return [] }
        return tree.children.map { TreeItem(node: $0, parentSize: tree.sizeOnDisk) }
    }

    func setRoot(_ url: URL) {
        root = url.standardizedFileURL
    }
}
