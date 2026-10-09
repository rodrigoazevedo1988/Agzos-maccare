import Foundation
import MacCareCore
import SwiftUI

/// ## Limpeza inteligente
///
/// A tela central do produto, e por isso a mais exigente em três pontos:
///
/// - **Nada começa sozinho.** A análise só roda quando o usuário pede. O PRD
///   §24 é explícito, e uma varredura automática na abertura transformaria um
///   app de manutenção em um processo que o usuário não pediu.
/// - **Todo item mostra motivo e consequência** antes da seleção. Um item sem
///   explicação é um item que o usuário não consegue julgar.
/// - **A contabilidade de espaço é rotulada com honestidade.** Mover para a
///   Lixeira não reduz o volume: o relatório diz exatamente isso em vez de
///   somar bytes como se tivessem sido liberados.
struct SmartCareView: View {

    let environment: AppEnvironment
    @State private var model = SmartCareModel()
    @State private var showConfirmation = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    scopeCard
                    errorBanner

                    if model.isAnalyzing {
                        ScanProgressCard(
                            title: "Analisando as pastas autorizadas",
                            progress: model.progress,
                            onCancel: { model.cancelAnalysis() }
                        )
                    }

                    if model.wasCancelled {
                        LimitationNotice(
                            "A análise foi cancelada. Nenhum resultado parcial é exibido, para não sugerir uma limpeza incompleta.",
                            severity: .information
                        )
                    }

                    if let report = model.report {
                        RemovalReportCard(report: report) { model.dismissReport() }
                    }

                    if let result = model.result {
                        results(result)
                    } else if !model.isAnalyzing {
                        idleState
                    }
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if model.result != nil && !model.isAnalyzing {
                Divider().overlay(Theme.Palette.separator)
                selectionFooter
            }
        }
        .background(Theme.Palette.canvas)
        .confirmationDialog(
            Text("Mover a seleção para a Lixeira?"),
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button(model.requiresReinforcedConfirmation
                   ? "Mover \(model.selectedCandidates.count) itens para a Lixeira mesmo assim"
                   : "Mover \(model.selectedCandidates.count) itens para a Lixeira",
                   role: model.requiresReinforcedConfirmation ? .destructive : nil) {
                model.startCleanup(environment: environment)
            }
            Button("Cancelar", role: .cancel) { showConfirmation = false }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: - Escopo e estado inicial

    /// O escopo é literal: mostrar os caminhos reais é o que permite ao
    /// usuário conferir o que autorizou antes de disparar a varredura.
    private var scopeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(
                    "O que será analisado",
                    subtitle: "Somente estas pastas. Nada é varrido ao abrir a tela."
                )

                if let scope = environment.scope {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        ForEach(scope.roots, id: \.path) { root in
                            PathLabel(abbreviated(root))
                        }
                    }

                    if scope.includeDownloads {
                        Text("Downloads está incluído, então downloads antigos entram apenas como sugestão — nunca vêm marcados.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                } else {
                    LimitationNotice(
                        "Nenhuma pasta está autorizada. Abra Ajustes e escolha o escopo antes de analisar.",
                        severity: .warning
                    )
                }

                HStack {
                    PrimaryActionButton("Analisar", symbol: "sparkles", isBusy: model.isAnalyzing) {
                        model.startAnalysis(environment: environment)
                    }
                    .disabled(environment.scope == nil || model.isCleaning)

                    if model.result != nil && !model.isAnalyzing {
                        Text("Uma nova análise descarta a seleção atual.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var errorBanner: some View {
        Group {
            if let message = model.errorMessage {
                LimitationNotice(message, severity: .warning)
            }
        }
    }

    private var idleState: some View {
        EmptyStateView(
            symbol: "sparkles",
            title: "Nenhuma análise executada",
            message: "A varredura percorre apenas as pastas autorizadas acima, leva em conta o que o aplicativo consegue regenerar e mostra o motivo de cada item antes de qualquer seleção.",
            actionLabel: "Analisar agora"
        ) {
            model.startAnalysis(environment: environment)
        }
    }

    // MARK: - Resultados

    @ViewBuilder
    private func results(_ result: SmartScanResult) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(
                "Resultado da análise",
                subtitle: summaryText(result)
            )

            if result.inaccessiblePaths.isEmpty {
                LimitationNotice(
                    "Todas as pastas autorizadas foram lidas. Os totais abaixo somam apenas arquivos com tamanho medido.",
                    severity: .information
                )
            } else {
                LimitationNotice(
                    "\(result.inaccessiblePaths.count) pasta\(result.inaccessiblePaths.count == 1 ? "" : "s") não puderam ser lidas e não entram em nenhum total. O macOS só libera o que você autorizou.",
                    severity: .warning
                )

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ForEach(result.inaccessiblePaths.prefix(8), id: \.self) { path in
                        PathLabel(abbreviated(URL(fileURLWithPath: path)))
                    }
                    if result.inaccessiblePaths.count > 8 {
                        Text("e mais \(result.inaccessiblePaths.count - 8) caminho\(result.inaccessiblePaths.count - 8 == 1 ? "" : "s")")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                }
            }

            if result.groups.isEmpty {
                EmptyStateView(
                    symbol: "checkmark.circle",
                    title: "Nada a limpar",
                    message: "A análise terminou e não encontrou itens recuperáveis dentro do escopo autorizado."
                )
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(result.groups) { group in
                        categoryGroup(group)
                    }
                }
            }
        }
    }

    private func summaryText(_ result: SmartScanResult) -> String {
        let duration = result.finishedAt.timeIntervalSince(result.startedAt)
        return "\(result.totalCandidates) candidatos · \(ByteSizeFormatter.format(result.totalRecoverable)) recuperáveis · \(String(format: "%.1f", duration)) s de varredura"
    }

    private func categoryGroup(_ group: CleanupCategoryGroup) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(group.id)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Divider().overlay(Theme.Palette.separator)

                HStack(spacing: Theme.Spacing.md) {
                    Toggle(isOn: groupSelectionBinding(group)) {
                        Text("Marcar todos os \(group.candidates.count) itens desta categoria")
                            .font(Theme.Typography.bodySmall)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    .toggleStyle(.checkbox)

                    Spacer(minLength: 0)

                    if group.hasUnmeasuredItems {
                        Badge("Há itens sem tamanho medido", color: Theme.Palette.warning)
                    }

                    Text("\(model.selectedCount(in: group)) de \(group.candidates.count) selecionados")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }

                ForEach(group.candidates) { candidate in
                    CandidateRow(
                        candidate: candidate,
                        isSelected: model.isSelected(candidate),
                        onToggle: { model.setSelected($0, for: candidate) }
                    )
                }
            }
            .padding(.top, Theme.Spacing.sm)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: group.category.symbolName)
                    .font(Theme.Typography.bodyLarge)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(group.category.title)
                        .font(Theme.Typography.titleSmall)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("\(group.candidates.count) itens · \(ByteSizeFormatter.format(group.measurableSize)) medidos")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }

                Spacer(minLength: Theme.Spacing.md)

                if group.category.requiresReinforcedConfirmation {
                    Badge("Confirmação reforçada", color: Theme.Palette.warning)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 0.5)
        )
    }

    // MARK: - Rodapé de seleção

    private var selectionFooter: some View {
        HStack(spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 1) {
                Text(footerTitle)
                    .font(Theme.Typography.bodyLarge)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(footerDetail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }

            Spacer(minLength: Theme.Spacing.md)

            if model.requiresReinforcedConfirmation {
                Badge("Inclui itens que não podem ser restaurados", color: Theme.Palette.warning)
            }

            if model.isCleaning {
                // A limpeza é executada em lotes pelo núcleo. Não há botão de
                // cancelar aqui de propósito: interromper no meio deixa parte
                // dos itens na Lixeira e parte no disco, que é o pior dos dois
                // estados. O app informa que está trabalhando e termina.
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Movendo para a Lixeira…")
                        .font(Theme.Typography.bodyLarge)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            } else {
                Button("Mover para a Lixeira") { showConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canRunCleanup)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface)
    }

    private var footerTitle: String {
        let count = model.selectedCandidates.count
        return count == 0
            ? "Nenhum item selecionado"
            : "\(count) \(count == 1 ? "item selecionado" : "itens selecionados") · \(ByteSizeFormatter.format(model.selectedTotalSize))"
    }

    /// O rodapé diz onde o espaço **não** foi. É a diferença entre "12 GB
    /// recuperados" e "12 GB foram movidos para a Lixeira".
    private var footerDetail: String {
        if model.selectedCandidates.isEmpty {
            return "Marque os itens que deseja mover. Nada é removido sem a confirmação."
        }
        if model.selectedUnmeasuredCount > 0 {
            return "O total cobre apenas os itens com tamanho medido. \(model.selectedUnmeasuredCount) \(model.selectedUnmeasuredCount == 1 ? "item ficou" : "itens ficaram") de fora por não serem mensuráveis."
        }
        return "Mover para a Lixeira não reduz o espaço do disco: o conteúdo continua ocupando o volume até você esvaziar a Lixeira."
    }

    // MARK: - Confirmação

    private var confirmationMessage: String {
        guard model.requiresReinforcedConfirmation else {
            return "Os \(model.selectedCandidates.count) itens selecionados serão movidos para a Lixeira. Você pode restaurá-los depois."
        }

        let names = model.reinforcedCategories.map(\.title).joined(separator: ", ")
        return "Esta seleção inclui itens que não podem ser restaurados: \(names). Nessa categoria o conteúdo pode existir apenas ali, e mover para a Lixeira é o primeiro passo de uma remoção que se torna definitiva assim que a Lixeira for esvaziada. Revise item por item antes de continuar."
    }

    // MARK: - Bindings

    private func expansionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.expandedGroupIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    model.expandedGroupIDs.insert(id)
                } else {
                    model.expandedGroupIDs.remove(id)
                }
            }
        )
    }

    private func groupSelectionBinding(_ group: CleanupCategoryGroup) -> Binding<Bool> {
        Binding(
            get: { model.isGroupSelected(group) },
            set: { model.setGroup(group, selected: $0) }
        )
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}

// MARK: - Progresso da varredura

/// Progresso real, com os três números que o `ScanProgress` entrega.
///
/// Mostrar "Analisando…" sem contador seria uma caixa-preta: o usuário não
/// tem como saber se o app está trabalhando ou travado em um disco lento.
struct ScanProgressCard: View {

    let title: String
    let progress: ScanProgress
    let onCancel: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                ProgressRing(
                    fraction: progress.fraction,
                    label: ByteSizeFormatter.percent(progress.fraction)
                )
                .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(title)
                        .font(Theme.Typography.titleSmall)
                        .foregroundStyle(Theme.Palette.primaryText)

                    HStack(spacing: Theme.Spacing.xl) {
                        metric("Arquivos visitados", "\(progress.filesVisited)")
                        metric("Itens encontrados", "\(progress.matchesFound)")
                        metric("Bytes encontrados", ByteSizeFormatter.compact(progress.bytesMatched))
                    }

                    if let current = progress.currentPath {
                        PathLabel(current)
                    }
                }

                Spacer(minLength: Theme.Spacing.md)

                Button("Cancelar", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
    }

    private func metric(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Theme.Typography.metricSmall)
                .foregroundStyle(Theme.Palette.primaryText)
            Text(caption)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
        }
    }
}

// MARK: - Item candidato

/// Uma linha da análise.
///
/// A ordem das informações é intencional: nome e tamanho primeiro, caminho
/// depois, e só então motivo e consequência. O usuário lê o que é, decide se
/// reconhece, e então julga o que acontece.
private struct CandidateRow: View {

    let candidate: CleanupCandidate
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Toggle(candidate.displayName, isOn: Binding(get: { isSelected }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(candidate.displayName)
                        .font(Theme.Typography.bodyLarge)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Badge(candidate.confidence.label, color: confidenceTint)

                    if candidate.isDirectory {
                        Badge("Pasta", color: Theme.Palette.secondaryText)
                    }

                    if candidate.isInSyncedFolder {
                        Badge("Pasta sincronizada", color: Theme.Palette.accent)
                    }
                }

                PathLabel(abbreviated(candidate.url))

                Text(candidate.reason)
                    .font(Theme.Typography.bodySmall)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let consequence = candidate.consequence {
                    HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(Theme.Typography.iconSmall)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                            .padding(.top, 3)
                        Text(consequence)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.md)

            Text(sizeText)
                .font(Theme.Typography.metricSmall)
                .foregroundStyle(Theme.Palette.primaryText)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(isSelected ? Theme.Palette.accentSubtle : Color.clear)
        )
    }

    /// `nil` é "não foi possível medir", e o rótulo diz exatamente isso.
    /// Mostrar "0 bytes" seria pior que mostrar nada.
    private var sizeText: String {
        guard let size = candidate.sizeOnDisk else { return "Sem tamanho" }
        return ByteSizeFormatter.format(size)
    }

    private var confidenceTint: Color {
        switch candidate.confidence {
        case .certain: return Theme.Palette.success
        case .likely: return Theme.Palette.accent
        case .uncertain: return Theme.Palette.warning
        }
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}

// MARK: - Relatório da operação

/// O que de fato aconteceu com cada item, e o que a contabilidade de espaço
/// consegue — e não consegue — afirmar.
struct RemovalReportCard: View {

    let report: RemovalReport
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "O que aconteceu",
                subtitle: report.summary,
                actionLabel: "Fechar",
                action: onDismiss
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Theme.Metrics.tileMinWidth), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                StatTile(
                    "Liberado confirmado",
                    symbol: "checkmark.circle",
                    tint: Theme.Palette.success,
                    value: .available(ByteSizeFormatter.format(report.accounting.releasedConfirmed)),
                    caption: "Redução do volume medida antes e depois da operação."
                )

                StatTile(
                    "Movido para a Lixeira",
                    symbol: "trash",
                    tint: Theme.Palette.accent,
                    value: .available(ByteSizeFormatter.format(report.accounting.releasedUnconfirmed)),
                    caption: "Ainda ocupa o disco. O espaço só é livre depois de esvaziar a Lixeira."
                )

                StatTile(
                    "Falhas",
                    symbol: "exclamationmark.triangle",
                    tint: report.accounting.failedItems > 0 ? Theme.Palette.danger : Theme.Palette.secondaryText,
                    value: .available("\(report.accounting.failedItems)"),
                    caption: report.accounting.failedItems > 0
                        ? "Esses itens foram mantidos intactos."
                        : "Nenhum item ficou sem resposta."
                )
            }

            if !report.movedToTrash.isEmpty {
                outcomeList(
                    "Movidos para a Lixeira",
                    outcomes: report.movedToTrash,
                    tint: Theme.Palette.success
                )
            }

            if !report.skipped.isEmpty {
                outcomeList(
                    "Ignorados por segurança",
                    outcomes: report.skipped,
                    tint: Theme.Palette.warning
                )
            }

            if !report.failed.isEmpty {
                outcomeList(
                    "Falharam",
                    outcomes: report.failed,
                    tint: Theme.Palette.danger
                )
            }

            if report.strategy == .moveToTrash && report.accounting.releasedConfirmed == 0 {
                LimitationNotice(
                    "Nenhum espaço foi liberado de fato. Mandar para a Lixeira apenas muda onde o arquivo está — o volume continua ocupado até a Lixeira ser esvaziada.",
                    severity: .information
                )
            }
        }
    }

    private func outcomeList(
        _ title: String,
        outcomes: [RemovalOutcome],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Typography.captionEmphasized)
                .foregroundStyle(tint)

            ForEach(outcomes.prefix(12)) { outcome in
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(outcome.url.lastPathComponent.isEmpty ? outcome.url.path : outcome.url.lastPathComponent)
                            .font(Theme.Typography.bodySmall)
                            .foregroundStyle(Theme.Palette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let reason = outcome.reason {
                            Text(reason)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: Theme.Spacing.sm)

                    if let size = outcome.measuredSize {
                        Text(ByteSizeFormatter.format(size))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                }
            }

            if outcomes.count > 12 {
                Text("e mais \(outcomes.count - 12) \(outcomes.count - 12 == 1 ? "item" : "itens")")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 0.5)
        )
    }
}
