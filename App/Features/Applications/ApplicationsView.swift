import AppKit
import MacCareCore
import SwiftUI

/// ## Aplicativos
///
/// Lista o que está instalado, mostra de onde veio cada item e oferece a
/// desinstalação **de terceiros** com revisão item a item dos residuais.
///
/// Três restrições do sistema moldam esta tela:
///
/// - O macOS não oferece um serviço público que diga se um aplicativo
///   instalado está desatualizado. Por isso não existe coluna de atualização:
///   afirmar "há versão nova" seria inventar.
/// - Aplicativos da Apple não são removidos pelo app. O botão existe, desativado,
///   com a explicação no lugar — sumir com o botão deixaria o usuário sem
///   entender por que a desinstalação existe para alguns e não para outros.
/// - A listagem é cara e pode ser parcial. A tela diz quando é parcial.
struct ApplicationsView: View {

    let environment: AppEnvironment

    /// O modelo nasce com o ambiente injetado pela navegação. Construí-lo com
    /// um `AppEnvironment()` próprio criaria um segundo histórico de operações e
    /// um segundo escopo — dois ambientes discordando sobre o que é removível.
    @State private var model: ApplicationsModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: ApplicationsModel(environment: environment))
    }

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                controls

                if let notice = model.partialListingNotice {
                    LimitationNotice(notice, severity: .warning)
                }

                if let message = model.errorMessage {
                    errorCard(message)
                }

                listing
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.Palette.canvas)
        .task {
            model.load()
        }
        .sheet(item: $model.appForUninstall) { application in
            UninstallerSheet(application: application, environment: environment) {
                model.reloadAfterRemoval()
            }
        }
    }

    /// Falha de uma ação pontual — abrir um app, selecionar no Finder.
    ///
    /// Fica na tela, e não em um alerta que some sozinho: a causa costuma ser
    /// permissão ou bundle inválido, e o usuário precisa conseguir reler o
    /// motivo depois de tentar outra coisa.
    private func errorCard(_ message: String) -> some View {
        Card(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                LimitationNotice(message, severity: .warning)

                HStack {
                    Spacer(minLength: 0)
                    Button("Dispensar") {
                        model.clearError()
                    }
                    .buttonStyle(.link)
                    .font(Theme.Typography.body)
                }
            }
        }
    }

    // MARK: - Controles

    private var controls: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Aplicativos instalados",
                subtitle: subtitle,
                actionLabel: model.phase == .listing ? "Cancelar leitura" : "Atualizar",
                action: {
                    if model.phase == .listing {
                        model.cancelLoad()
                    } else {
                        model.load(force: true)
                    }
                }
            )

            Card {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.md) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "magnifyingglass")
                                .font(Theme.Typography.bodySmall)
                                .foregroundStyle(Theme.Palette.tertiaryText)

                            TextField("Buscar por nome, identificador ou caminho", text: $model.searchText)
                                .textFieldStyle(.plain)
                                .font(Theme.Typography.bodyLarge)
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                .fill(Theme.Palette.canvas)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                .strokeBorder(Theme.Palette.border, lineWidth: 0.5)
                        )

                        Picker("Localização", selection: $model.locationFilter) {
                            ForEach(ApplicationsModel.LocationFilter.allCases, id: \.self) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 190)

                        Picker("Ordenar por", selection: $model.sortOrder) {
                            ForEach(ApplicationsModel.SortOrder.allCases, id: \.self) { order in
                                Text(order.label).tag(order)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 165)
                    }

                    if model.phase == .listing {
                        progressRow
                    }
                }
            }
        }
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)

                Text("Lendo o Info.plist e medindo o tamanho de cada aplicativo…")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.secondaryText)

                Spacer(minLength: 0)

                if model.exceededTimeLimit {
                    Text("Demorando mais de \(Int(ApplicationsModel.timeLimit))s")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.warning)
                }

                Button("Parar de esperar", role: .cancel) {
                    model.cancelLoad()
                }
                .buttonStyle(.link)
                .font(Theme.Typography.body)
                .help("A leitura em disco não é interrompida — o resultado é descartado quando terminar.")
            }

            Text("A leitura percorre cada bundle para medir o tamanho em disco. O cancelamento impede que o resultado apareça, mas não encerra a leitura em andamento.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .idle, .listing:
            return "A listagem ainda não terminou."
        case .ready:
            guard model.totalCount > 0 else {
                return "Nenhum aplicativo encontrado nas pastas monitoradas."
            }
            if model.visibleCount == model.totalCount {
                return "\(model.totalCount) aplicativos em \(model.lastDuration.formatted(.number.precision(.fractionLength(1)))) s de leitura."
            }
            return "Exibindo \(model.visibleCount) de \(model.totalCount) aplicativos."
        }
    }

    // MARK: - Listagem

    @ViewBuilder
    private var listing: some View {
        if model.phase == .idle {
            Card {
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Preparando a listagem de aplicativos…")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
        } else if model.phase == .listing {
            // A leitura em andamento já tem indicador, tempo e botão de
            // parar nos controles. Repetir um "carregando" aqui seria ruído.
            EmptyView()
        } else if model.isEmpty {
            Card {
                EmptyStateView(
                    symbol: "square.grid.2x2",
                    title: "Nenhum aplicativo encontrado",
                    message: "O MacCare procurou em /Applications e ~/Applications. Nenhum bundle com Info.plist legível foi encontrado nessas pastas.",
                    actionLabel: "Procurar de novo",
                    action: { model.load(force: true) }
                )
            }
        } else if model.visibleCount == 0 {
            Card {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "Nenhum aplicativo corresponde ao filtro",
                    message: "Ajuste a busca ou escolha outra localização para ver os \(model.totalCount) aplicativos encontrados.",
                    actionLabel: "Limpar filtros",
                    action: {
                        model.searchText = ""
                        model.locationFilter = .all
                    }
                )
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                if !model.appleApps.isEmpty {
                    section(
                        title: "Aplicativos da Apple",
                        subtitle: "Componentes do macOS. O MacCare não os desinstala: removê-los pode comprometer atualizações e funcionalidades do sistema. Use a App Store ou o Finder, se quiser removê-los.",
                        entries: model.appleApps
                    )
                }

                if !model.thirdPartyApps.isEmpty {
                    section(
                        title: "Aplicativos de terceiros",
                        subtitle: "Instalados fora do sistema. A desinstalação mostra cada resíduo antes de remover qualquer coisa.",
                        entries: model.thirdPartyApps
                    )
                }
            }
        }
    }

    private func section(title: String, subtitle: String, entries: [ApplicationEntry]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title, subtitle: subtitle)

            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(entries) { entry in
                    ApplicationRow(entry: entry, model: model)
                }
            }
        }
    }
}

// MARK: - Linha do aplicativo

/// Uma linha: identidade, versão, tamanho, caminho e três ações.
///
/// Os botões são iconográficos e não rotulados porque o nome do aplicativo
/// ocupa a largura; cada um tem `help` explicando o que faz, e as ações
/// destrutivas nunca ficam sem rótulo.
private struct ApplicationRow: View {

    let entry: ApplicationEntry
    let model: ApplicationsModel

    var body: some View {
        Card(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Image(systemName: entry.isAppleProvided ? "apple.logo" : "app.badge")
                        .font(Theme.Typography.bodyLarge)
                        .foregroundStyle(entry.isAppleProvided ? Theme.Palette.secondaryText : Theme.Palette.accent)
                        .frame(width: 20)

                    Text(entry.name)
                        .font(Theme.Typography.titleSmall)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .lineLimit(1)

                    if entry.isAppleProvided {
                        Badge("Apple", color: Theme.Palette.secondaryText)
                    }

                    if entry.isInSyncedFolder {
                        Badge("Pasta sincronizada", color: Theme.Palette.accent)
                    }

                    Spacer(minLength: Theme.Spacing.sm)

                    Text(sizeText)
                        .font(Theme.Typography.metricSmall)
                        .foregroundStyle(sizeTint)
                        .monospacedDigit()
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Text(entry.versionSummary)
                    if let category = entry.category, !category.isEmpty {
                        Text("·")
                        Text(category)
                    }
                    Text("·")
                    Text(entry.location.title)
                }
                .font(Theme.Typography.bodySmall)
                .foregroundStyle(Theme.Palette.secondaryText)
                .lineLimit(1)

                PathLabel(entry.url.path)

                HStack(spacing: Theme.Spacing.md) {
                    actionButton("play.circle", "Abrir o aplicativo") {
                        model.launch(entry)
                    }

                    actionButton("folder", "Mostrar no Finder") {
                        model.revealInFinder(entry)
                    }

                    Spacer(minLength: 0)

                    uninstallButton
                }
                .padding(.top, Theme.Spacing.xxs)
            }
        }
    }

    private var sizeText: String {
        guard let size = entry.sizeOnDisk else { return "Não medido" }
        return ByteSizeFormatter.format(size)
    }

    private var sizeTint: Color {
        entry.sizeOnDisk == nil ? Theme.Palette.unavailable : Theme.Palette.primaryText
    }

    private func actionButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.Typography.bodyLarge)
                .foregroundStyle(Theme.Palette.accent)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
    }

    /// A desinstalação de apps da Apple fica **visível e desativada**.
    ///
    /// Um botão que some seria mais limpo, mas o usuário não saberia se o app
    /// esqueceu o caso ou se algo o impediu. O botão inativo com explicação é
    /// a resposta honesta.
    @ViewBuilder
    private var uninstallButton: some View {
        if entry.isAppleProvided {
            Button("Desinstalar", action: {})
                .buttonStyle(.borderless)
                .font(Theme.Typography.bodySmall)
                .disabled(true)
                .help("O MacCare não desinstala aplicativos da Apple. Eles pertencem ao sistema operacional.")
        } else {
            Button {
                model.appForUninstall = entry
            } label: {
                Label("Desinstalar", systemImage: "trash")
                    .font(Theme.Typography.bodySmall)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Palette.danger)
            .help("Revisar o aplicativo e os residuais antes de remover qualquer coisa")
        }
    }
}
