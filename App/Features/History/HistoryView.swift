import MacCareCore
import SwiftUI

/// ## Histórico
///
/// O que o MacCare já fez, quando, e com que resultado contábil. A tela é uma
/// lista reversa agrupada por dia, e cada registro mostra os quatro números de
/// espaço com os rótulos que eles realmente têm — inclusive o "não confirmado",
/// que é o número honesto para tudo que foi para a Lixeira.
///
/// Duas ações existem: apagar e exportar. Apagar é destrutivo e pede
/// confirmação; exportar escreve a versão **redigida** do log, e a tela diz o
/// que isso significa antes de o usuário escolher o destino.
@MainActor
struct HistoryView: View {

    @State private var model: HistoryModel
    @State private var isConfirmingClear = false
    @State private var isExporting = false
    @State private var exportDocument: RedactedHistoryExport?

    init(environment: AppEnvironment) {
        _model = State(wrappedValue: HistoryModel(environment: environment))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                summary
                actions

                if let errorMessage = model.errorMessage {
                    errorNotice(errorMessage)
                }

                if let cleared = model.lastClearedCount {
                    notice(
                        symbol: "trash",
                        tint: Theme.Palette.secondaryText,
                        text: cleared == 0
                            ? "O histórico já estava vazio."
                            : "\(cleared) registro(s) apagados. Nenhuma operação foi desfeita por isso: a Lixeira continua sendo o caminho de volta dos itens removidos."
                    )
                }

                if model.isLoading {
                    loading
                } else if model.isEmpty {
                    emptyState
                } else {
                    dayGroups
                }

                privacyNote
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.Palette.canvas)
        .task {
            await model.load()
        }
        .confirmationDialog(
            "Apagar todo o histórico?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Apagar \(model.totalRecords) registro(s)", role: .destructive) {
                Task { await model.clearHistory() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O histórico é apagado de forma definitiva e não pode ser recuperado. Isso não desfaz nenhuma operação já realizada — itens enviados para a Lixeira continuam lá, com a possibilidade de restauração.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .macCareHistory,
            defaultFilename: "historico-maccare.jsonl"
        ) { result in
            if case .failure(let error) = result {
                model.reportError("A exportação não foi concluída: \(error.localizedDescription)")
            }
            exportDocument = nil
        }
    }

    // MARK: - Resumo

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Operações registradas",
                subtitle: model.isEmpty
                    ? "Nenhuma operação foi executada ainda."
                    : "\(model.totalRecords) registro(s) em \(model.groups.count) dia(s)."
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Theme.Metrics.tileMinWidth), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                StatTile(
                    "Operações",
                    symbol: "list.bullet.rectangle",
                    tint: Theme.Palette.accent,
                    value: .available("\(model.totalRecords)"),
                    caption: "Registros no histórico local"
                )

                StatTile(
                    "Itens processados",
                    symbol: "shippingbox",
                    tint: Theme.Palette.secondaryText,
                    value: .available("\(model.totalItemsProcessed)"),
                    caption: "Somando processados, ignorados e falhos"
                )

                StatTile(
                    "Liberado confirmado",
                    symbol: "checkmark.circle",
                    tint: Theme.Palette.success,
                    value: .available(ByteSizeFormatter.compact(model.totalReleasedConfirmed)),
                    caption: "Redução medida no volume após a operação"
                )

                StatTile(
                    "Liberado não confirmado",
                    symbol: "questionmark.circle",
                    tint: Theme.Palette.warning,
                    value: .available(ByteSizeFormatter.compact(model.totalReleasedUnconfirmed)),
                    caption: "Processado, mas sem redução mensurável — típico da Lixeira"
                )
            }
        }
    }

    // MARK: - Ações

    private var actions: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                Task {
                    if let document = await model.makeExportDocument() {
                        exportDocument = document
                        isExporting = true
                    }
                }
            } label: {
                Label("Exportar histórico", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.isEmpty || model.isClearing)
            .help("Salva um arquivo com os mesmos registros, com o nome do usuário substituído por ~")

            Button(role: .destructive) {
                isConfirmingClear = true
            } label: {
                Label("Limpar histórico", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.isEmpty || model.isClearing)

            if model.isClearing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Lista

    private var dayGroups: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(group.title)
                            .font(Theme.Typography.titleMedium)
                            .foregroundStyle(Theme.Palette.primaryText)
                        Text("\(group.entries.count)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                        Rectangle()
                            .fill(Theme.Palette.separator)
                            .frame(height: 1)
                    }

                    ForEach(group.entries) { entry in
                        entryCard(entry)
                    }
                }
            }
        }
    }

    private func entryCard(_ entry: HistoryModel.Entry) -> some View {
        let record = entry.record

        return Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Button {
                    model.toggleExpansion(entry)
                } label: {
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        Image(systemName: record.kind.symbolName)
                            .font(Theme.Typography.bodyLarge)
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 20)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.kind.title)
                                .font(Theme.Typography.titleSmall)
                                .foregroundStyle(Theme.Palette.primaryText)
                            Text("\(entry.timeText) · \(record.strategy)")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.tertiaryText)
                        }

                        Spacer(minLength: Theme.Spacing.sm)

                        if record.failedCount > 0 {
                            Badge("\(record.failedCount) falharam", color: Theme.Palette.danger)
                        }

                        Image(systemName: model.isExpanded(entry) ? "chevron.up" : "chevron.down")
                            .font(Theme.Typography.iconSmall)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                countsRow(record)
                accountingRow(record.accounting)

                if model.isExpanded(entry) {
                    Divider().overlay(Theme.Palette.separator)
                    details(record)
                }
            }
        }
    }

    private func countsRow(_ record: OperationRecord) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            countCell("Processados", record.itemCount, Theme.Palette.primaryText)
            countCell("Concluídos", record.succeededCount, Theme.Palette.success)
            countCell("Ignorados", record.skippedCount, Theme.Palette.secondaryText)
            countCell("Falhados", record.failedCount, record.failedCount > 0 ? Theme.Palette.danger : Theme.Palette.secondaryText)
            Spacer(minLength: 0)
        }
    }

    private func countCell(_ title: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("\(value)")
                .font(Theme.Typography.metricSmall)
                .foregroundStyle(color)
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
        }
    }

    /// A contabilidade de espaço, com os quatro rótulos do domínio.
    ///
    /// "Liberado confirmado" e "liberado não confirmado" ficam lado a lado de
    /// propósito: somar os dois produziria um número maior que o espaço que
    /// voltou, e a diferença entre eles é informação, não ruído.
    private func accountingRow(_ accounting: SpaceAccounting) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            accountingCell(
                "Identificado",
                accounting.identified,
                "Soma dos candidatos encontrados pela análise, antes de qualquer seleção sua."
            )
            accountingCell(
                "Selecionado",
                accounting.selected,
                "Soma dos itens que você marcou antes de executar a operação."
            )
            accountingCell(
                "Liberado confirmado",
                accounting.releasedConfirmed,
                "Redução medida no volume depois da operação. Só é maior que zero quando a exclusão foi definitiva."
            )
            accountingCell(
                "Liberado não confirmado",
                accounting.releasedUnconfirmed,
                "Processado, mas a redução não pôde ser confirmada. É o caso de tudo que foi para a Lixeira, que continua ocupando o mesmo volume."
            )
        }
    }

    private func accountingCell(_ title: String, _ bytes: Int64, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
            Text(ByteSizeFormatter.format(bytes))
                .font(Theme.Typography.metricSmall)
                .foregroundStyle(Theme.Palette.primaryText)
        }
        .help(help)
    }

    @ViewBuilder
    private func details(_ record: OperationRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Caminhos afetados (\(record.affectedPaths.count))")
                    .font(Theme.Typography.captionEmphasized)
                    .foregroundStyle(Theme.Palette.secondaryText)

                if record.affectedPaths.isEmpty {
                    Text("Nenhum caminho foi registrado nesta operação.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        // Índices em vez dos próprios caminhos: dois caminhos
                        // repetidos no mesmo registro quebrariam a identidade do
                        // ForEach, e um histórico malformado não pode derrubar
                        // a tela.
                        ForEach(record.affectedPaths.indices, id: \.self) { index in
                            PathLabel(record.affectedPaths[index])
                        }
                    }
                }
            }

            if !record.notes.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Observações")
                        .font(Theme.Typography.captionEmphasized)
                        .foregroundStyle(Theme.Palette.secondaryText)

                    ForEach(record.notes.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                            Text("·")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.tertiaryText)
                            Text(record.notes[index])
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Estados e avisos

    private var loading: some View {
        Card {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView().controlSize(.small)
                Text("Lendo o histórico…")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
    }

    private var emptyState: some View {
        Card {
            EmptyStateView(
                symbol: "clock.arrow.circlepath",
                title: "Nada foi feito ainda",
                message: "O histórico registra apenas operações que o MacCare executou: limpezas, revisões e verificações. Enquanto nenhuma delas rodar, esta lista fica vazia — e o aplicativo não inventa registros para parecer mais ocupado."
            )
        }
    }

    private var privacyNote: some View {
        LimitationNotice(
            """
            A exportação é sempre a versão redigida: o nome da sua pasta pessoal é \
            substituído por "~" em todos os caminhos. O arquivo não inclui conta, e-mail, \
            identificador de máquina nem nenhum dado pessoal — e continua aqui no seu Mac, \
            gravado apenas onde você escolher.
            """
        )
    }

    private func errorNotice(_ message: String) -> some View {
        notice(symbol: "exclamationmark.triangle", tint: Theme.Palette.warning, text: message)
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
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }
}
