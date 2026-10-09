import SwiftUI

/// ## Ajustes
///
/// Cinco seções, e a primeira é a que importa: o escopo. Ela é a autorização do
/// MacCare para olhar qualquer coisa, então mostra os caminhos literais,
/// explica o que cada um é, e permite revogá-los. Todas as telas do aplicativo
/// obedecem a essa lista — não é uma preferência de exibição.
///
/// A tela de aparência é propositalmente curta e sem interruptor: o aplicativo
/// acompanha o sistema. Oferecer "Claro/Escuro" aqui sem que a escolha valesse
/// para alguma coisa seria um controle decorativo, e controles decorativos são
/// a forma mais barata de um aplicativo quebrar a confiança do usuário.
@MainActor
struct SettingsView: View {

    @State private var model: SettingsModel
    @State private var isConfirmingClearHistory = false

    init(environment: AppEnvironment) {
        _model = State(wrappedValue: SettingsModel(environment: environment))
    }

    var body: some View {
        Form {
            scopeSection
            messagesSection
            appearanceSection
            dataSection
            permissionsSection
            aboutSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas)
        .task {
            await model.loadHistory()
        }
        .confirmationDialog(
            "Apagar todo o histórico?",
            isPresented: $isConfirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button("Apagar histórico", role: .destructive) {
                Task { await model.clearHistory() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O registro das operações é apagado de forma definitiva. Isso não desfaz nenhuma limpeza já executada: itens enviados para a Lixeira continuam lá.")
        }
    }

    // MARK: - Escopo

    private var scopeSection: some View {
        Section {
            if model.scopeRoots.isEmpty {
                LimitationNotice(
                    "Nenhuma pasta está autorizada para análise. Sem escopo, as telas que dependem de leitura de disco dizem isso em vez de mostrar um resultado inventado.",
                    severity: .warning
                )
            } else {
                ForEach(model.scopeRoots, id: \.path) { root in
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "folder")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.accent)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.description(for: root))
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.primaryText)
                            PathLabel(model.abbreviatedPath(root))
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Theme.Spacing.xxs)
                }
            }

            Toggle(
                "Incluir ~/Downloads na análise",
                isOn: Binding(
                    get: { model.includeDownloads },
                    set: { model.setIncludeDownloads($0) }
                )
            )
            .padding(.vertical, Theme.Spacing.xxs)
        } header: {
            Text("Escopo de análise")
        } footer: {
            Text("O MacCare só lê — e só pode limpar — o que estiver nesta lista. Ao mudar a opção, o escopo é reconstruído e as autorizações anteriores deixam de valer imediatamente, inclusive a autorização de remoção. Downloads entram desmarcados por padrão: é a pasta onde documentos do usuário se misturam a instaladores, e varrê-la sem pedido explícito seria uma surpresa.")
        }
    }

    // MARK: - Mensagens

    /// Confirmação de efeito: toda mudança de escopo produz uma linha dizendo o
    /// que mudou de fato. Um interruptor que muda algo em silêncio obriga o
    /// usuário a adivinhar se funcionou.
    @ViewBuilder
    private var messagesSection: some View {
        if let error = model.errorMessage {
            Section {
                notice(symbol: "exclamationmark.triangle", tint: Theme.Palette.warning, text: error)
            }
        } else if let status = model.statusMessage {
            Section {
                notice(symbol: "checkmark.circle", tint: Theme.Palette.success, text: status)
            }
        }
    }

    private func notice(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(Theme.Typography.caption)
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(Theme.Typography.bodySmall)
                .foregroundStyle(Theme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: - Aparência

    private var appearanceSection: some View {
        Section {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Acompanha o sistema")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("Em Ajustes do Sistema › Aparência")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Spacing.xxs)
        } header: {
            Text("Aparência")
        } footer: {
            Text("O aplicativo segue o Claro, o Escuro e o modo automático do macOS, sem configuração própria. Um seletor de tema aqui teria de valer para todas as telas — e um seletor que não muda nada é pior do que não existir.")
        }
    }

    // MARK: - Dados

    private var dataSection: some View {
        Section {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "internaldrive")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Histórico de operações")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text(historySummary)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }

                Spacer(minLength: 0)

                if model.isLoadingHistory || model.isClearingHistory {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)

            Button(role: .destructive) {
                isConfirmingClearHistory = true
            } label: {
                Label("Limpar histórico", systemImage: "trash")
            }
            .disabled(model.historyRecordCount == 0 || model.isClearingHistory)

            Divider().overlay(Theme.Palette.separator)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Onde os dados ficam")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                PathLabel(model.historyFolderText + "/", lineLimit: 2)
                PathLabel(model.historyLocationText, lineLimit: 2)
                Text(model.historyFileExists
                     ? "Este arquivo existe agora. Ele é criado no primeiro registro e apagado por completo quando você limpa o histórico."
                     : "Este arquivo ainda não existe: nada é gravado antes da primeira operação registrada.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.Spacing.xxs)

            Divider().overlay(Theme.Palette.separator)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                promiseRow("network.slash", "Nada sai deste Mac")
                promiseRow("antenna.radiowaves.left.and.right.slash", "Sem telemetria e sem internet")
                promiseRow("person.crop.circle", "Sem conta, sem login e sem e-mail")
            }
            .padding(.vertical, Theme.Spacing.xxs)
        } header: {
            Text("Dados")
        } footer: {
            Text("O aplicativo funciona totalmente offline e sem conta. Não existe envio de diagnóstico, sincronização em nuvem nem compartilhamento de arquivos com terceiros. O que ele analisa, ele analisa localmente — inclusive quando o Mac está sem rede.")
        }
    }

    private var historySummary: String {
        guard let count = model.historyRecordCount else { return "Não foi possível ler o histórico." }
        if count == 0 { return "Nenhuma operação registrada." }
        return count == 1 ? "1 operação registrada." : "\(count) operações registradas."
    }

    private func promiseRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(Theme.Typography.bodySmall)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 18)
                .padding(.top, 1)
            Text(text)
                .font(Theme.Typography.bodySmall)
                .foregroundStyle(Theme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Permissões

    private var permissionsSection: some View {
        Section {
            LimitationNotice(
                """
                O MacCare não solicita Acesso Completo ao Disco e funciona sem ele. \
                Ele analisa apenas o que o macOS já autoriza e declara, item a item, o \
                que não conseguiu ler — em vez de estimar, preencher com zero ou \
                esconder a lacuna.

                Se você já concedeu Acesso Completo ao Disco a este aplicativo por um \
                motivo que não se lembra, a forma de reverter isso é remover a \
                autorização na tela do sistema, e o aplicativo não faz isso por você.
                """
            )
            .padding(.vertical, Theme.Spacing.xs)
        } header: {
            Text("Permissões")
        } footer: {
            Text("Nenhuma permissão é pedida nesta tela. Pedir o disco inteiro para ler o que já está em ~/Library/Caches seria trocar transparência por um número de arquivos a mais.")
        }
    }

    // MARK: - Sobre

    private var aboutSection: some View {
        Section {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "checkmark.shield")
                    .font(Theme.Typography.titleSmall)
                    .foregroundStyle(Theme.Palette.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Agzos MacCare")
                        .font(Theme.Typography.bodyLarge)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("Versão \(model.appVersion ?? "Indisponível") · build \(model.appBuild ?? "Indisponível")")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Spacing.xs)

            Divider().overlay(Theme.Palette.separator)

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Limitações conhecidas")
                    .font(Theme.Typography.titleSmall)
                    .foregroundStyle(Theme.Palette.primaryText)

                Text("Restrições reais do macOS, não omissões do aplicativo. Elas não vão desaparecer em versões futuras.")
                    .font(Theme.Typography.bodySmall)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(SettingsModel.knownLimitations) { limitation in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "exclamationmark.circle")
                                .font(Theme.Typography.micro)
                                .foregroundStyle(Theme.Palette.warning)
                            Text(limitation.title)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.primaryText)
                        }
                        Text(limitation.detail)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        } header: {
            Text("Sobre")
        } footer: {
            Text("MacCare não é antivírus, não acessa a internet e não pede conta. Se alguma tela mostrar um número que você não entende, prefira o estado “Indisponível” — ele é a informação verdadeira.")
        }
    }
}
