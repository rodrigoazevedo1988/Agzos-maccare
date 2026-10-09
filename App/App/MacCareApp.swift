import MacCareCore
import SwiftUI

@main
struct MacCareApp: App {

    @State private var environment = AppEnvironment()
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model, environment: environment)
                .frame(
                    minWidth: Theme.Metrics.minWindowWidth,
                    minHeight: Theme.Metrics.minWindowHeight
                )
                // O app se comporta como um documento único: abrir dois
                // $("#MacCare") com históricos diferentes criaria ambiguidade
                // sobre qual é o estado autoritativo das operações.
                .defaultSize(width: 1180, height: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Ferramentas") {
                Button("Análise inteligente") { model.go(to: .smartCare) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Analisar armazenamento") { model.go(to: .storage) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Localizar arquivos grandes") { model.go(to: .largeFiles) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Button("Atualizar agora") {
                    Task { await model.refreshSnapshot() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing)
            }
        }
    }
}

// MARK: - Raiz

struct RootView: View {

    @Bindable var model: AppModel
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        // `@Bindable` e necessario aqui porque a largura da coluna e um
        // `Binding`. As telas abaixo recebem o modelo como valor simples.
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView(selection: $model.selectedFeature)
                .navigationSplitViewColumnWidth(
                    min: Theme.Metrics.sidebarWidth - 40,
                    ideal: Theme.Metrics.sidebarWidth,
                    max: Theme.Metrics.sidebarWidth + 60
                )
        } detail: {
            VStack(spacing: 0) {
                ContextHeader(feature: model.selectedFeature, model: model)
                Divider().overlay(Theme.Palette.separator)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.Palette.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            // Uma coleta na abertura. O PRD §24 proíbe análises profundas
            // automáticas — este passo lê métricas do host, que é barato e
            // instantâneo, e não varre o disco.
            await model.refreshSnapshot()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedFeature {
        case .dashboard:     DashboardView(model: model, environment: environment)
        case .smartCare:     SmartCareView(environment: environment)
        case .storage:       StorageAnalyzerView(environment: environment)
        case .largeFiles:    LargeFilesView(environment: environment)
        case .duplicates:    DuplicatesView(environment: environment)
        case .applications:  ApplicationsView(environment: environment)
        case .performance:   PerformanceView(model: model)
        case .startupItems:  StartupItemsView(environment: environment)
        case .privacy:       PrivacyView(environment: environment)
        case .protection:    ProtectionView(environment: environment)
        case .history:       HistoryView(environment: environment)
        case .settings:      SettingsView(environment: environment)
        }
    }
}

// MARK: - Cabeçalho contextual

/// Cabeçalho que acompanha o módulo selecionado.
///
/// O subtítulo não é decorativo: em um app com este número de módulos, é ele
/// que impede o usuário de precisar lembrar o que cada tela faz.
struct ContextHeader: View {

    let feature: Feature
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title)
                    .font(Theme.Typography.titleLarge)
                    .foregroundStyle(Theme.Palette.primaryText)

                Text(feature.subtitle)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }

            Spacer(minLength: Theme.Spacing.md)

            if let snapshot = model.snapshot {
                HStack(spacing: Theme.Spacing.xs) {
                    Circle()
                        .fill(Theme.Palette.success)
                        .frame(width: 6, height: 6)
                    Text("Atualizado \(snapshot.capturedAt.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
                .help("Última leitura de estado do sistema")
            }

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Palette.canvas)
    }
}

// MARK: - Barra lateral

struct SidebarView: View {

    @Binding var selection: Feature?
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        List(selection: $selection) {
            ForEach(Feature.Section.allCases, id: \.self) { section in
                Section(section.title) {
                    ForEach(features(in: section)) { feature in
                        Label(feature.title, systemImage: feature.symbol)
                            .tag(feature)
                            .font(Theme.Typography.bodyLarge)
                    }
                }
            }

            Section {
                scopeRow
            } header: {
                Text("Escopo de análise")
            } footer: {
                Text("O MacCare só analisa as pastas autorizadas aqui.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas)
    }

    private func features(in section: Feature.Section) -> [Feature] {
        Feature.allCases.filter { $0.section == section }
    }

    /// Mostra o escopo ativo de forma literal.
    ///
    /// Exibir os caminhos reais no menu é o que permite ao usuário verificar
    /// se entendeu o que autorizou. Um rótulo como "pastas selecionadas" não
    /// informa nada.
    private var scopeRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if let scope = environment.scope {
                ForEach(scope.roots, id: \.path) { root in
                    PathLabel(abbreviated(root))
                }
            } else {
                Text("Nenhuma pasta autorizada")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.warning)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    /// Substitui a pasta do usuário por `~` — legível e menos revelador.
    private func abbreviated(_ url: URL) -> String {
        guard let home = FileManager.default.homeDirectoryForCurrentUser.path else {
            return url.path
        }
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}
