import MacCareCore
import SwiftUI

/// ## Visão geral
///
/// Responde a uma pergunta e a nenhuma outra: *como está o meu Mac agora?*.
///
/// A tela não exibe uma "nota de saúde". Exibe medidas, e abaixo delas as
/// recomendações que a `RecommendationEngine` conseguiu derivar **com base em
/// medidas que existem**. Quando uma medida não existe, o bloco correspondente
/// diz "Indisponível" — e nenhuma recomendação é inventada sobre ele.
struct DashboardView: View {

    let model: AppModel
    let environment: AppEnvironment

    private let recommendations = RecommendationEngine()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                deviceHeader

                if let snapshot = model.snapshot {
                    metricsGrid(snapshot)
                    insightsSection(snapshot)
                } else {
                    loadingState
                }

                quickActions
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.Palette.canvas)
    }

    // MARK: - Identidade

    private var deviceHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(model.snapshot?.device.displayName ?? "Mac")
                .font(Theme.Typography.displayLarge)
                .foregroundStyle(Theme.Palette.primaryText)

            HStack(spacing: Theme.Spacing.sm) {
                if let device = model.snapshot?.device {
                    Text(device.processorSummary)
                    Text("·")
                    Text("\(ByteSizeFormatter.format(device.physicalMemory)) de memória")
                    Text("·")
                    Text("macOS \(device.osVersion) (\(device.osBuild))")
                } else {
                    Text("Coletando informações do sistema…")
                }
            }
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Métricas

    private func metricsGrid(_ snapshot: SystemSnapshot) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Theme.Metrics.tileMinWidth), spacing: Theme.Spacing.md)],
            spacing: Theme.Spacing.md
        ) {
            StatTile(
                "Processador",
                symbol: "cpu",
                tint: cpuTint(snapshot.cpu),
                value: snapshot.cpu.map { ByteSizeFormatter.percent($0.busy) },
                caption: snapshot.cpu.map { "Usuário \(ByteSizeFormatter.percent($0.user)) · Sistema \(ByteSizeFormatter.percent($0.system))" } ?? nil
            )

            StatTile(
                "Memória",
                symbol: "memorychip",
                tint: Theme.Palette.accent,
                value: snapshot.memory.map { "\(ByteSizeFormatter.format($0.used)) / \(ByteSizeFormatter.format($0.physical))" },
                caption: snapshot.memory.value.map { memoryCaption($0) }
            )

            StatTile(
                "Disco",
                symbol: "internaldrive",
                tint: diskTint(snapshot.volume),
                value: snapshot.volume.map { "\(ByteSizeFormatter.format($0.availableCapacity)) livres" },
                caption: snapshot.volume.map { ByteSizeFormatter.percent($0.usedFraction) + " em uso" } ?? nil
            )

            StatTile(
                "Bateria",
                symbol: "battery.75",
                tint: Theme.Palette.success,
                value: snapshot.battery.map { "\($0.chargePercent)%" },
                caption: snapshot.battery.map { $0.isCharging ? "Carregando" : ($0.isPluggedIn ? "Ligado à energia" : "Uso de bateria") } ?? nil
            )

            StatTile(
                "Processos",
                symbol: "square.stack.3d.up",
                tint: Theme.Palette.secondaryText,
                value: .available("\(snapshot.totalProcessCount)"),
                caption: "Em execução neste momento"
            )

            // A temperatura entra sempre, mesmo indisponível.
            //
            // Mostrar o bloco "Indisponível" é uma escolha: escondê-lo faria o
            // usuário procurar um sensor que existe em parte dos Macs e concluir
            // que o app não está mostrando o que poderia. Dizer que não há API
            // pública é a informação correta.
            StatTile(
                "Temperatura",
                symbol: "thermometer.medium",
                tint: Theme.Palette.unavailable,
                value: .unavailable(.noPublicAPI)
            )
        }
    }

    private func memoryCaption(_ usage: MemoryUsage) -> String {
        var parts = ["Ativos \(ByteSizeFormatter.format(usage.active))", "Ligados \(ByteSizeFormatter.format(usage.wired))"]
        if usage.compressed > 0 { parts.append("Comprimida \(ByteSizeFormatter.format(usage.compressed))") }
        if let swap = usage.swapUsed, swap > 0 { parts.append("Swap \(ByteSizeFormatter.format(swap))") }
        return parts.joined(separator: " · ")
    }

    private func cpuTint(_ cpu: Measurement<CPUUsage>) -> Color {
        guard case .available(let usage) = cpu, usage.busy > InsightThresholds.highCPUFraction else {
            return Theme.Palette.accent
        }
        return Theme.Palette.warning
    }

    private func diskTint(_ volume: Measurement<VolumeUsage>) -> Color {
        guard case .available(let usage) = volume else { return Theme.Palette.accent }
        let free = usage.availableFraction
        if free < InsightThresholds.criticalFreeSpaceFraction { return Theme.Palette.danger }
        if free < InsightThresholds.lowFreeSpaceFraction { return Theme.Palette.warning }
        return Theme.Palette.accent
    }

    // MARK: - Recomendações

    @ViewBuilder
    private func insightsSection(_ snapshot: SystemSnapshot) -> some View {
        let insights = recommendations.insights(from: snapshot)

        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Recomendações",
                subtitle: insights.isEmpty
                    ? "Nada disparou os critérios de atenção."
                    : "Derivadas de medidas reais do seu Mac."
            )

            if insights.isEmpty {
                Card {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.Palette.success)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nenhuma atenção necessária")
                                .font(Theme.Typography.titleSmall)
                                .foregroundStyle(Theme.Palette.primaryText)
                            Text("Os indicadores coletados estão dentro dos limites definidos. Isso não é uma avaliação de segurança.")
                                .font(Theme.Typography.bodySmall)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                ForEach(insights) { insight in
                    InsightCard(insight: insight) {
                        guard let destination = insight.destination else { return }
                        model.go(to: Feature(destinationFeature(destination)))
                    }
                }
            }
        }
    }

    private func destinationFeature(_ destination: InsightDestination) -> Feature {
        switch destination {
        case .storage: return .storage
        case .largeFiles: return .largeFiles
        case .duplicates: return .duplicates
        case .smartCare: return .smartCare
        case .applications: return .applications
        case .performance: return .performance
        case .startupItems: return .startupItems
        }
    }

    // MARK: - Ações rápidas

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader("Ações rápidas")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190), spacing: Theme.Spacing.sm)],
                spacing: Theme.Spacing.sm
            ) {
                QuickActionButton("Análise inteligente", "sparkles", .smartCare) { model.go(to: $0) }
                QuickActionButton("Analisar armazenamento", "internaldrive", .storage) { model.go(to: $0) }
                QuickActionButton("Localizar arquivos grandes", "doc.text.magnifyingglass", .largeFiles) { model.go(to: $0) }
                QuickActionButton("Revisar aplicativos", "square.grid.2x2", .applications) { model.go(to: $0) }
                QuickActionButton("Monitorar desempenho", "chart.xyaxis.line", .performance) { model.go(to: $0) }
                QuickActionButton("Revisar privacidade", "hand.raised", .privacy) { model.go(to: $0) }
                QuickActionButton("Verificações de segurança", "checkmark.shield", .protection) { model.go(to: $0) }
                QuickActionButton("Histórico de operações", "clock.arrow.circlepath", .history) { model.go(to: $0) }
            }
        }
    }

    // MARK: - Estados

    private var loadingState: some View {
        Card {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView().controlSize(.small)
                Text("Coletando o estado do sistema…")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
    }
}

// MARK: - Cartão de recomendação

/// Cada recomendação mostra a **evidência** e o **critério**.
///
/// É o oposto de um alerta genérico. O usuário consegue concordar ou discordar
/// do limiar, que é o que torna a recomendação auditável em vez de autoritária.
private struct InsightCard: View {

    let insight: Insight
    let action: () -> Void

    private var tint: Color {
        switch insight.severity {
        case .action: return Theme.Palette.danger
        case .attention: return Theme.Palette.warning
        case .information: return Theme.Palette.accent
        }
    }

    private var symbol: String {
        switch insight.severity {
        case .action: return "exclamationmark.triangle.fill"
        case .attention: return "exclamationmark.circle"
        case .information: return "info.circle"
        }
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(insight.title)
                        .font(Theme.Typography.titleSmall)
                        .foregroundStyle(Theme.Palette.primaryText)

                    Text(insight.evidence)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(insight.criterion)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Theme.Spacing.sm)

                if insight.suggestedAction != nil {
                    Button(insight.suggestedAction ?? "", action: action)
                        .buttonStyle(.link)
                        .font(Theme.Typography.body)
                }
            }
        }
    }
}

// MARK: - Botão de ação rápida

private struct QuickActionButton: View {

    let title: String
    let symbol: String
    let destination: Feature
    let action: (Feature) -> Void

    @State private var isHovering = false

    var body: some View {
        Button { action(destination) } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 18)

                Text(title)
                    .font(Theme.Typography.bodyLarge)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(isHovering ? Theme.Palette.surfaceElevated : Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.quick, value: isHovering)
    }
}
