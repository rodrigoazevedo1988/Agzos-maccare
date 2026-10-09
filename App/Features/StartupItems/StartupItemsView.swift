import MacCareCore
import SwiftUI

/// ## Itens de inicialização
///
/// A tela mais curta de prometer e a mais importante de cumprir.
///
/// O macOS não dá a outro aplicativo o direito de desligar itens de
/// inicialização de terceiros. A tentação óbvia — um botão de "desativar" por
/// linha — produziria um controle que mente. Aqui não existe: existe a lista
/// com a origem de cada item, a instrução exata de onde resolver e um atalho
/// que abre a tela certa das Configurações do Sistema.
///
/// A segunda regra é estrutural: **esta tela não tem caminho de remoção**.
/// Apagar um `LaunchAgent` para "desativar" algo é uma perda de arquivo
/// silenciosa disfarçada de configuração. O `StartupItemsModel` só lê.
struct StartupItemsView: View {

    let environment: AppEnvironment

    @State private var model: StartupItemsModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: StartupItemsModel(environment: environment))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header

                LimitationNotice(
                    "O macOS não oferece API pública para desativar itens de inicialização de outros aplicativos: a alteração só é possível para o próprio app que os instalou. Por isso o MacCare não mostra botões de desativar — ele informa o que existe, de onde vem e onde resolver. Nada nesta tela apaga arquivos.",
                    severity: .information
                )

                if let message = model.errorMessage {
                    Card(padding: Theme.Spacing.md) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            LimitationNotice(message, severity: .warning)

                            HStack {
                                Spacer(minLength: 0)
                                Button("Dispensar") {
                                    model.dismissError()
                                }
                                .buttonStyle(.link)
                                .font(Theme.Typography.body)
                            }
                        }
                    }
                }

                listing
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.Palette.canvas)
        .task {
            model.scan()
        }
    }

    // MARK: - Cabeçalho

    private var header: some View {
        Group {
            if model.phase == .scanning {
                SectionHeader("O que roda junto com o seu Mac", subtitle: subtitle)
            } else {
                SectionHeader(
                    "O que roda junto com o seu Mac",
                    subtitle: subtitle,
                    actionLabel: "Varrer novamente",
                    action: { model.scan() }
                )
            }
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .idle, .scanning:
            return "Lendo LaunchAgents e LaunchDaemons do sistema e da sua conta."
        case .ready:
            guard !model.isEmpty else {
                return "Nenhum item de inicialização legível foi encontrado."
            }
            return "\(model.thirdPartyCount) itens de terceiros e \(model.systemCount) itens do macOS."
        }
    }

    // MARK: - Listagem

    @ViewBuilder
    private var listing: some View {
        if model.phase == .scanning {
            Card {
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Lendo os diretórios de inicialização…")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
        } else if model.isEmpty {
            Card {
                EmptyStateView(
                    symbol: "power",
                    title: "Nenhum item de inicialização encontrado",
                    message: "A varredura cobriu /Library/LaunchDaemons, /Library/LaunchAgents e os mesmos diretórios da sua conta de usuário. Nenhum arquivo .plist legível foi encontrado neles.",
                    actionLabel: "Varrer novamente",
                    action: { model.scan() }
                )
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                if !model.thirdPartySections.isEmpty {
                    ForEach(model.thirdPartySections) { section in
                        sectionView(section)
                    }
                }

                if !model.systemSections.isEmpty {
                    ForEach(model.systemSections) { section in
                        sectionView(section)
                    }
                }
            }
        }
    }

    private func sectionView(_ section: StartupItemsModel.Section) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(section.title, subtitle: section.subtitle)

            ForEach(section.groups) { group in
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(group.source.title)
                            .font(Theme.Typography.titleSmall)
                            .foregroundStyle(Theme.Palette.primaryText)

                        Badge("\(group.items.count)", color: Theme.Palette.secondaryText)
                    }

                    Card(padding: Theme.Spacing.xs) {
                        VStack(spacing: 0) {
                            ForEach(group.items) { item in
                                itemRow(item)
                                if item.id != group.items.last?.id {
                                    Divider().overlay(Theme.Palette.separator)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Item

    private func itemRow(_ item: StartupItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Image(systemName: item.isSystemProvided ? "gearshape.2" : "cube")
                    .font(Theme.Typography.body)
                    .foregroundStyle(item.isSystemProvided ? Theme.Palette.secondaryText : Theme.Palette.accent)
                    .frame(width: 18)

                Text(item.label)
                    .font(Theme.Typography.titleSmall)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .textSelection(.enabled)
                    .lineLimit(1)

                Badge(item.kind.title, color: Theme.Palette.secondaryText)

                if item.isCurrentlyRunning {
                    Badge("Carregado agora", color: Theme.Palette.success, filled: true)
                }

                Spacer(minLength: Theme.Spacing.sm)

                stateLabel(item)
            }

            if let summary = item.summary, !summary.isEmpty {
                PathLabel(summary)
            }

            PathLabel(item.url.path)

            if let explanation = model.stateExplanation(for: item) {
                HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                    Image(systemName: "info.circle")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .padding(.top, 2)

                    Text(explanation)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actionArea(item)
        }
        .padding(Theme.Spacing.md)
    }

    /// Estado do item, com o rótulo "Indisponível" quando o macOS não informa.
    @ViewBuilder
    private func stateLabel(_ item: StartupItem) -> some View {
        switch item.isEnabled {
        case .some(let isEnabled):
            Badge(
                isEnabled ? "Habilitado" : "Desabilitado",
                color: isEnabled ? Theme.Palette.success : Theme.Palette.secondaryText
            )
        case .none:
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: "minus")
                    .font(Theme.Typography.iconSmall)
                Text("Indisponível")
                    .font(Theme.Typography.captionEmphasized)
            }
            .foregroundStyle(Theme.Palette.unavailable)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Palette.unavailable.opacity(0.14))
            )
            .help("O macOS não expõe por API pública o estado de habilitação deste item.")
        }
    }

    /// A área de ação é a parte honesta da linha.
    ///
    /// - Item de terceiros: um botão que **abre as Configurações do Sistema** e
    ///   a instrução escrita, que fica na tela mesmo que o usuário não abra nada.
    /// - Item do sistema: texto explicando que o app não mexe naquilo. Nenhum
    ///   botão, porque não existe ação honesta a oferecer.
    @ViewBuilder
    private func actionArea(_ item: StartupItem) -> some View {
        if item.isSystemProvided {
            HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                Image(systemName: "lock")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .padding(.top, 2)

                Text(model.guidance(for: item))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.md) {
                    Button {
                        model.toggleGuidance(for: item)
                    } label: {
                        Label(
                            model.isRevealed(item) ? "Ocultar instrução" : "Como resolver",
                            systemImage: "questionmark.circle"
                        )
                        .font(Theme.Typography.bodySmall)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Palette.accent)
                    .help("Mostra o caminho exato para desativar este item nas Configurações do Sistema")

                    if model.settingsURL(for: item) != nil {
                        Button {
                            model.openSettings(for: item)
                        } label: {
                            Label("Abrir Configurações do Sistema", systemImage: "arrow.up.forward.app")
                                .font(Theme.Typography.bodySmall)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.Palette.accent)
                        .help("Abre a tela de Itens de login e extensões")
                    }
                }

                // A instrução fica sempre disponível: se o botão falhar, se o
                // usuário não quiser sair do app, ou se ele simplesmente quiser
                // saber o que fazer depois.
                if model.isRevealed(item) || model.settingsURL(for: item) == nil {
                    Card(padding: Theme.Spacing.md) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(model.guidance(for: item))
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.primaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("O MacCare não executa esta alteração. Desativar um item de inicialização é uma configuração do macOS, não uma limpeza de arquivos.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
