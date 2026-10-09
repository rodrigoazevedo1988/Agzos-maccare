import MacCareCore
import Observation
import SwiftUI

// NOTA: este arquivo estava vazio no repositório (0 bytes) e o app não
// compilava sem ele. O conteúdo abaixo foi reconstruído a partir do uso em
// `MacCareApp.swift`, `DashboardView.swift` e `PerformanceModel.swift`:
// navegação entre módulos e a fotografia compartilhada do sistema.

/// Módulos do aplicativo, na ordem da barra lateral.
enum Feature: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dashboard
    case smartCare
    case storage
    case largeFiles
    case duplicates
    case applications
    case performance
    case startupItems
    case privacy
    case protection
    case history
    case settings

    var id: String { rawValue }

    /// Agrupamento da barra lateral.
    enum Section: String, CaseIterable, Hashable, Sendable {
        case overview
        case cleanup
        case maintenance
        case app

        var title: String {
            switch self {
            case .overview: return "Visão geral"
            case .cleanup: return "Limpeza"
            case .maintenance: return "Manutenção"
            case .app: return "MacCare"
            }
        }
    }

    var section: Section {
        switch self {
        case .dashboard, .smartCare: return .overview
        case .storage, .largeFiles, .duplicates, .applications: return .cleanup
        case .performance, .startupItems, .privacy, .protection: return .maintenance
        case .history, .settings: return .app
        }
    }

    var title: String {
        switch self {
        case .dashboard: return "Visão geral"
        case .smartCare: return "Análise inteligente"
        case .storage: return "Armazenamento"
        case .largeFiles: return "Arquivos grandes"
        case .duplicates: return "Duplicados"
        case .applications: return "Aplicativos"
        case .performance: return "Desempenho"
        case .startupItems: return "Itens de inicialização"
        case .privacy: return "Privacidade"
        case .protection: return "Proteção"
        case .history: return "Histórico"
        case .settings: return "Ajustes"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: return "Como está o seu Mac agora, com medidas reais."
        case .smartCare: return "Uma análise consolidada; nada é removido sem a sua confirmação."
        case .storage: return "O que ocupa espaço no disco, por pasta."
        case .largeFiles: return "Arquivos grandes e antigos nas pastas autorizadas."
        case .duplicates: return "Arquivos com conteúdo idêntico, comparado por hash."
        case .applications: return "Aplicativos instalados e desinstalação item a item."
        case .performance: return "CPU, memória, processos e bateria."
        case .startupItems: return "O que abre junto com o macOS."
        case .privacy: return "Históricos e caches de navegação."
        case .protection: return "Verificações de segurança do sistema."
        case .history: return "Registro local de todas as operações."
        case .settings: return "Escopo de análise e preferências."
        }
    }

    /// Símbolo SF Symbols da barra lateral.
    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .smartCare: return "sparkles"
        case .storage: return "internaldrive"
        case .largeFiles: return "doc.text.magnifyingglass"
        case .duplicates: return "doc.on.doc"
        case .applications: return "square.grid.2x2"
        case .performance: return "chart.xyaxis.line"
        case .startupItems: return "power"
        case .privacy: return "hand.raised"
        case .protection: return "checkmark.shield"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// Estado de navegação e a fotografia do sistema compartilhada entre telas.
@Observable
@MainActor
final class AppModel {

    var selectedFeature: Feature = .dashboard
    var columnVisibility: NavigationSplitViewVisibility = .all

    /// Ponte para `List(selection:)`, que exige um opcional. Desmarcar na
    /// barra lateral não deixa o app sem tela: `nil` é ignorado.
    var sidebarSelection: Feature? {
        get { selectedFeature }
        set { if let newValue { selectedFeature = newValue } }
    }

    private(set) var snapshot: SystemSnapshot?
    private(set) var isRefreshing = false

    private let metrics: HostMetricsCollector

    init(metrics: HostMetricsCollector = HostMetricsCollector()) {
        self.metrics = metrics
    }

    func go(to feature: Feature) {
        selectedFeature = feature
    }

    /// Coleta uma nova fotografia do sistema fora da thread principal.
    ///
    /// Só lê métricas do host (barato). Não varre o disco: o PRD §24 proíbe
    /// análises profundas automáticas.
    func refreshSnapshot() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let collector = metrics
        let captured = await Task.detached(priority: .userInitiated) { () -> SystemSnapshot in
            let processes = collector.listProcesses(limit: 50)
            return SystemSnapshot(
                capturedAt: Date(),
                device: collector.deviceIdentity(),
                cpu: collector.cpuUsage(),
                memory: collector.memoryUsage(),
                volume: collector.volumeUsage(),
                battery: collector.batteryStatus(),
                topProcesses: processes.samples,
                totalProcessCount: processes.total
            )
        }.value
        snapshot = captured
    }
}
