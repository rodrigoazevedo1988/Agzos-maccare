import MacCareCore
import SwiftUI

/// ## Privacidade
///
/// A tela abre com o que o macOS **não** permite, porque essa é a informação
/// que evita a promessa falsa. Depois disso ela entrega caminhos, não botões
/// mágicos: cada tópico explica o assunto e abre a tela do sistema onde a
/// revisão acontece de fato.
///
/// A única seção com ação real é a de cache de navegadores, e ela é pequena de
/// propósito: identificam-se caminhos exatos, mostra-se o que sai do disco, e
/// nada é selecionado sem que o usuário marque.
@MainActor
struct PrivacyView: View {

    @State private var model: PrivacyModel
    @State private var isConfirmingCacheCleanup = false

    init(environment: AppEnvironment) {
        _model = State(wrappedValue: PrivacyModel(environment: environment))
    }

    var body: some View {
        Form {
            limitationSection

            if let errorMessage = model.errorMessage {
                errorSection(errorMessage)
            }

            reviewTopicsSection
            startupItemsSection
            browserCacheSection
            promiseSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas)
        .task {
            await model.loadStartupItems()
        }
        .confirmationDialog(
            "Mover os caches selecionados para a Lixeira?",
            isPresented: $isConfirmingCacheCleanup,
            titleVisibility: .visible
        ) {
            Button("Mover para a Lixeira", role: .destructive) {
                Task { await model.cleanSelectedCaches() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Cada item marcado será movido para a Lixeira, um a um, e poderá ser restaurado por lá. Itens não marcados não são tocados. Histórico, cookies, senhas e preenchimentos dos navegadores nunca são alcançados por esta ação.")
        }
    }

    // MARK: - Limitação principal

    private var limitationSection: some View {
        Section {
            LimitationNotice(
                """
                O macOS não expõe nenhuma API pública que permita a um aplicativo \
                listar — nem revogar — as permissões de câmera, microfone, \
                localização e arquivos dos outros aplicativos. Essa tabela é \
                mantida pelo sistema e só pode ser vista por você, na tela de \
                Configurações.

                Por isso o MacCare não mostra uma lista de aplicativos com acesso \
                concedido. Ele faz o que pode: mostrar exatamente onde revisar cada \
                permissão, abrir essa tela para você, e dizer com clareza o que ele \
                não consegue ver. Nada nesta tela concede, revoga ou altera \
                qualquer configuração do sistema.
                """,
                severity: .warning
            )
            .padding(.vertical, Theme.Spacing.xs)
        } header: {
            Text("O que este aplicativo consegue ver")
        } footer: {
            Text("Uma lista de permissões que o macOS não deixa ler seria uma lista inventada. Preferimos indicar o caminho exato e não afirmar o que não sabemos.")
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.warning)
                    .padding(.top, 1)
                Text(message)
                    .font(Theme.Typography.bodySmall)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Tópicos de revisão

    private var reviewTopicsSection: some View {
        ForEach(model.topics) { topic in
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(topic.explanation)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(topic.links) { link in
                            Button {
                                model.open(link)
                            } label: {
                                Label(link.label, systemImage: "arrow.up.forward.square")
                                    .font(Theme.Typography.body)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Abre a tela do sistema. O MacCare não altera nenhuma configuração.")
                        }
                    }
                    .padding(.top, Theme.Spacing.xxs)
                }
                .padding(.vertical, Theme.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Label(topic.title, systemImage: topic.symbolName)
            } footer: {
                Text(topic.manualPath)
                    .font(Theme.Typography.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Itens de inicialização

    private var startupItemsSection: some View {
        Section {
            if model.isLoadingStartupItems {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Lendo itens de inicialização…")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            } else if model.thirdPartyStartupItems.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Nenhum item de terceiros encontrado")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("Só há itens do próprio macOS, que não devem ser alterados.")
                        .font(Theme.Typography.bodySmall)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Theme.Spacing.xs)
            } else {
                ForEach(Array(model.thirdPartyStartupItems.prefix(6))) { item in
                    startupItemRow(item)
                }

                if model.thirdPartyStartupItems.count > 6 {
                    Text("E mais \(model.thirdPartyStartupItems.count - 6) item(ns) de terceiros. A lista completa está no módulo Inicialização.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    model.openLoginItemsSettings()
                } label: {
                    Label("Abrir Itens de login e extensões", systemImage: "arrow.up.forward.square")
                        .font(Theme.Typography.body)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } header: {
            Text("Itens de inicialização")
        } footer: {
            Text("O MacCare apenas lê e informa. O macOS não permite, por API pública, alterar itens de inicialização de terceiros: a mudança é feita por você em Itens de login e extensões. Nada nesta seção é desligado pelo aplicativo.")
        }
    }

    private func startupItemRow(_ item: StartupItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(item.label)
                    .font(Theme.Typography.bodyLarge)
                    .foregroundStyle(Theme.Palette.primaryText)
                Badge(item.kind.title, color: Theme.Palette.secondaryText)
            }

            Text(StartupItemGuidance.instruction(for: item))
                .font(Theme.Typography.bodySmall)
                .foregroundStyle(Theme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if StartupItemGuidance.settingsURL(for: item) != nil {
                Button {
                    model.openSettings(for: item)
                } label: {
                    Text("Abrir a tela de Itens de login")
                        .font(Theme.Typography.caption)
                }
                .buttonStyle(.link)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Cache de navegadores

    private var browserCacheSection: some View {
        Section {
            if model.isMeasuringCaches {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Procurando e medindo caches de navegadores…")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.secondaryText)
                    Spacer(minLength: 0)
                    Button("Parar") { model.cancelMeasuringCaches() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else if model.browserCaches.isEmpty {
                EmptyStateView(
                    symbol: "safari",
                    title: "Nenhum cache de navegador encontrado",
                    message: "Nenhuma das pastas de cache conhecidas existe neste Mac, ou nenhuma pôde ser lida. Isso é normal em um Mac recém-instalado.",
                    actionLabel: "Procurar novamente",
                    action: { model.startMeasuringCaches() }
                )
            } else {
                ForEach(model.browserCaches) { cache in
                    browserCacheRow(cache)
                }

                selectionControls

                PrimaryActionButton(
                    "Limpar selecionados",
                    symbol: "trash",
                    isBusy: model.isCleaningCaches
                ) {
                    isConfirmingCacheCleanup = true
                }
                .disabled(model.selectedCacheCount == 0 || model.isCleaningCaches)
                .padding(.vertical, Theme.Spacing.xs)
            }

            if let outcome = model.cleanupOutcome {
                cleanupOutcomeView(outcome)
            }
        } header: {
            Text("Cache de navegadores (opcional)")
        } footer: {
            Text("Esta é a única limpeza que esta tela executa, e ela é estrita: apenas pastas de cache, que os navegadores recriam sozinhos. Nada é marcado por padrão — cada item entra no plano somente se você selecionar. O histórico, os cookies, as senhas e os preenchimentos não são alcançados por esta ação.")
        }
    }

    private func browserCacheRow(_ cache: PrivacyModel.BrowserCacheTarget) -> some View {
        Toggle(
            isOn: Binding(
                get: { model.isSelected(cache) },
                set: { model.setSelected(cache, $0) }
            )
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(cache.browserName)
                        .font(Theme.Typography.bodyLarge)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text(cacheSize(cache))
                        .font(Theme.Typography.captionEmphasized)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }

                PathLabel(cache.displayPath)

                Text(cache.whatIsRemoved)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.Spacing.xxs)
        }
        .toggleStyle(.checkbox)
    }

    /// O tamanho é uma medida real ou um "não foi possível medir".
    ///
    /// Nunca zero: um cache que não pôde ser lido — comum quando falta Acesso
    /// Completo ao Disco — não é um cache vazio.
    private func cacheSize(_ cache: PrivacyModel.BrowserCacheTarget) -> String {
        guard let size = cache.sizeOnDisk else { return "não foi possível medir" }
        return ByteSizeFormatter.format(size)
    }

    private var selectionControls: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(model.selectedCacheCount == 0
                 ? "Nenhum item selecionado"
                 : "\(model.selectedCacheCount) de \(model.browserCaches.count) selecionado(s)")
                .font(Theme.Typography.caption)
                .foregroundStyle(model.selectedCacheCount == 0 ? Theme.Palette.tertiaryText : Theme.Palette.secondaryText)

            Spacer(minLength: 0)

            Button("Selecionar todos") { model.selectAllCaches() }
                .buttonStyle(.link)
                .font(Theme.Typography.body)
                .disabled(model.selectedCacheCount == model.browserCaches.count)

            Button("Desmarcar") { model.clearSelection() }
                .buttonStyle(.link)
                .font(Theme.Typography.body)
                .disabled(model.selectedCacheCount == 0)
        }
    }

    private func cleanupOutcomeView(_ outcome: PrivacyModel.CleanupOutcome) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Divider().overlay(Theme.Palette.separator)

            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "checkmark.circle")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.success)
                Text("Resultado")
                    .font(Theme.Typography.titleSmall)
                    .foregroundStyle(Theme.Palette.primaryText)
                Spacer(minLength: 0)
                Text(outcome.browserNames.joined(separator: ", "))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }

            Text(outcome.summary)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Theme.Metrics.tileMinWidth), spacing: Theme.Spacing.sm)],
                spacing: Theme.Spacing.sm
            ) {
                accountingCell("Identificado", outcome.identified)
                accountingCell("Selecionado", outcome.selected)
                accountingCell("Liberado confirmado", outcome.releasedConfirmed)
                accountingCell("Liberado não confirmado", outcome.releasedUnconfirmed)
            }

            Text("Enviar para a Lixeira não reduz o espaço do disco imediatamente, porque a Lixeira mora no mesmo volume. Por isso o espaço liberado aparece como “não confirmado” — o número honesto, não o número que impressiona.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            if outcome.failedItems > 0 {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Palette.warning)
                    Text("\(outcome.failedItems) item(ns) não puderam ser movidos e foram mantidos intactos. O motivo está no histórico.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, Theme.Spacing.sm)
    }

    private func accountingCell(_ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
            Text(ByteSizeFormatter.format(bytes))
                .font(Theme.Typography.metricSmall)
                .foregroundStyle(Theme.Palette.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Promessa do aplicativo

    private var promiseSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                promiseRow("lock.shield", "Nada sai deste Mac", "Nenhuma informação é enviada para servidores, por nenhum motivo. Não há telemetria, sincronização ou conta.")
                promiseRow("wifi.slash", "Funciona sem internet", "Todas as funções rodam localmente, inclusive com o Mac totalmente desconectado.")
                promiseRow("person.crop.circle.badge.checkmark", "Sem conta e sem cadastro", "O MacCare não pede e-mail, não cria conta e não pede que você entre em lugar nenhum.")
                promiseRow("hand.raised", "Você marca, o app executa", "Nenhuma remoção acontece por um item simplesmente existir. Tudo o que sai do disco passa por uma seleção sua e por uma confirmação explícita.")
            }
            .padding(.vertical, Theme.Spacing.xs)
        } header: {
            Text("Privacidade, por padrão")
        }
    }

    private func promiseRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(Theme.Typography.bodySmall)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(detail)
                    .font(Theme.Typography.bodySmall)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
