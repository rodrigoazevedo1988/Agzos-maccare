import Foundation
import MacCareCore
import SwiftUI
import UniformTypeIdentifiers

/// ## Duplicados
///
/// Duplicidade aqui não é uma suspicion nem uma coincidência de nome: é
/// igualdade de conteúdo confirmada por SHA-256. É por isso que a tela pode
/// afirmar o que encontrou — e por isso que ela precisa ser cautelosa ao
/// oferecer a remoção.
///
/// Três avisos carregam o peso desta tela:
///
/// - **Hard links.** Dois caminhos podem apontar para o mesmo inode. Nesse
///   caso não são duas cópias: são o mesmo arquivo, e remover um caminho pode
///   apagar o conteúdo inteiro.
/// - **Pasta sincronizada.** Remover o lado local de um arquivo do iCloud
///   Drive propaga a exclusão para os outros dispositivos do usuário.
/// - **Nenhuma cópia preservada.** A seleção padrão preserva uma cópia, mas o
///   usuário pode desmarcar todas. O diálogo de confirmação nomeia os grupos
///   afetados antes de qualquer remoção.
struct DuplicatesView: View {

    let environment: AppEnvironment
    @State private var model = DuplicatesModel()

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    folderCard
                    errorBanner

                    if model.isSearching {
                        ScanProgressCard(
                            title: "Procurando cópias idênticas",
                            progress: model.progress,
                            onCancel: { model.cancelSearch() }
                        )
                    }

                    if model.wasCancelled {
                        LimitationNotice(
                            "A busca foi cancelada. Nenhum resultado parcial é exibido, para não sugerir que a análise terminou.",
                            severity: .information
                        )
                    }

                    if let report = model.report {
                        RemovalReportCard(report: report) { model.dismissReport() }
                    }

                    results
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if !model.groups.isEmpty {
                Divider().overlay(Theme.Palette.separator)
                selectionFooter
            }
        }
        .background(Theme.Palette.canvas)
        .fileImporter(
            isPresented: $model.isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { outcome in
            switch outcome {
            case .success(let urls):
                urls.forEach { model.addRoot($0) }
            case .failure(let error):
                model.errorMessage = "Não foi possível abrir o seletor de pastas: \(error.localizedDescription)"
            }
        }
        .confirmationDialog(
            Text("Remover as cópias selecionadas?"),
            isPresented: $model.showRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remover \(model.pendingRemoval.count) \(model.pendingRemoval.count == 1 ? "cópia" : "cópias")") {
                model.confirmRemoval(environment: environment)
            }
            Button("Cancelar", role: .cancel) { model.cancelRemovalRequest() }
        } message: {
            Text(removalMessage)
        }
    }

    // MARK: - Pastas

    private var folderCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(
                    "Pastas a verificar",
                    subtitle: "A busca calcula o hash do conteúdo e só declara duplicata a igualdade confirmada."
                )

                if model.roots.isEmpty {
                    Text("Nenhuma pasta escolhida ainda.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(model.roots, id: \.self) { root in
                            HStack(spacing: Theme.Spacing.sm) {
                                PathLabel(abbreviated(root))
                                Spacer(minLength: Theme.Spacing.md)
                                Button("Remover") { model.removeRoot(root) }
                                    .buttonStyle(.link)
                                    .font(Theme.Typography.bodySmall)
                            }
                        }
                    }
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Button("Escolher pasta…") { model.isChoosingFolder = true }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(model.isSearching)

                    if !model.suggestedRoots.isEmpty {
                        Text("Sugestões:")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)

                        ForEach(model.suggestedRoots, id: \.self) { suggestion in
                            Button(suggestion.lastPathComponent) { model.addRoot(suggestion) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.isSearching)
                        }
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

    // MARK: - Resultados

    @ViewBuilder
    private var results: some View {
        if model.groups.isEmpty && !model.isSearching {
            if model.hasSearched {
                EmptyStateView(
                    symbol: "checkmark.circle",
                    title: "Nenhum duplicado confirmado",
                    message: "A busca terminou e não encontrou dois arquivos com o mesmo conteúdo nas pastas escolhidas. Arquivos com nomes parecidos não contam: só entra no resultado o hash idêntico.",
                    actionLabel: "Buscar em outras pastas"
                ) {
                    model.isChoosingFolder = true
                }
            } else {
                EmptyStateView(
                    symbol: "square.on.square",
                    title: "Nenhuma busca executada",
                    message: "Escolha uma pasta e execute a busca. O MacCare compara tamanho, metadados e hash do conteúdo — nomes parecidos nunca são tratados como duplicidade.",
                    actionLabel: "Escolher pasta"
                ) {
                    model.isChoosingFolder = true
                }
            }
        } else if !model.groups.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(
                    "Grupos confirmados",
                    subtitle: "\(model.groups.count) grupos · \(ByteSizeFormatter.format(model.groups.reduce(0) { $0 + $1.reclaimableSize })) recuperáveis preservando uma cópia por grupo"
                )

                if model.progress.wasTruncated {
                    LimitationNotice(
                        "A busca atingiu o limite de tempo ou de arquivos e parou antes do fim. A lista está incompleta.",
                        severity: .warning
                    )
                }

                VStack(spacing: Theme.Spacing.md) {
                    ForEach(model.groups) { group in
                        duplicateGroup(group)
                    }
                }
            }
        }
    }

    private func duplicateGroup(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            DisclosureGroup(isExpanded: expansionBinding(group.id)) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Divider().overlay(Theme.Palette.separator)
                    groupWarnings(group)
                    groupItems(group)
                }
                .padding(.top, Theme.Spacing.sm)
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "square.on.square")
                        .font(Theme.Typography.bodyLarge)
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.items.first?.displayName ?? group.digest.prefix(12).description)
                            .font(Theme.Typography.titleSmall)
                            .foregroundStyle(Theme.Palette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(group.fileCount) cópias de \(ByteSizeFormatter.format(group.sizeOnDisk)) · \(ByteSizeFormatter.format(group.reclaimableSize)) recuperáveis")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }

                    Spacer(minLength: Theme.Spacing.md)

                    let kept = model.keptCount(in: group)
                    if kept == 0 {
                        Badge("Nenhuma cópia preservada", color: Theme.Palette.danger)
                    } else {
                        Badge("\(kept) \(kept == 1 ? "cópia preservada" : "cópias preservadas")", color: Theme.Palette.success)
                    }
                }
            }

            HStack(spacing: Theme.Spacing.md) {
                Text("SHA-256 \(group.digest.prefix(16).description)…")
                    .font(Theme.Typography.path)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .textSelection(.enabled)

                Spacer(minLength: Theme.Spacing.md)

                Button("Marcar todas menos a sugerida") { model.resetGroup(group) }
                    .buttonStyle(.link)
                    .font(Theme.Typography.bodySmall)
                    .disabled(model.isRemoving)

                Button("Desmarcar todas") { model.clearGroup(group) }
                    .buttonStyle(.link)
                    .font(Theme.Typography.bodySmall)
                    .disabled(model.isRemoving)
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

    /// Avisos que mudam o que significa remover neste grupo.
    @ViewBuilder
    private func groupWarnings(_ group: DuplicateGroup) -> some View {
        if group.containsHardLinks {
            LimitationNotice(
                "Este grupo contém hard links: são o mesmo arquivo, apontado por caminhos diferentes. Remover mais de um caminho pode apagar o conteúdo inteiro, porque as entradas apontam para o mesmo arquivo no disco.",
                severity: .warning
            )
        }

        if group.isInSyncedFolder {
            LimitationNotice(
                "Pelo menos uma cópia está em uma pasta sincronizada. Remover o lado local pode propagar a exclusão para os outros dispositivos signados na sua conta.",
                severity: .warning
            )
        }
    }

    private func groupItems(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(group.items) { item in
                let isKeep = model.isKeepSuggestion(item, in: group)

                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    Toggle(item.displayName, isOn: Binding(
                        get: { model.isSelected(item) },
                        set: { _ in model.toggle(item) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .padding(.top, 2)
                    .disabled(model.isRemoving)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(item.displayName)
                                .font(Theme.Typography.bodyLarge)
                                .foregroundStyle(Theme.Palette.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            if isKeep {
                                Badge("Sugerido: manter", color: Theme.Palette.accent)
                            }
                            if item.isInSyncedFolder {
                                Badge("Sincronizado", color: Theme.Palette.accent)
                            }
                        }

                        PathLabel(abbreviated(item.url))

                        Text(modificationText(item))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }

                    Spacer(minLength: Theme.Spacing.md)

                    Text(ByteSizeFormatter.format(item.sizeOnDisk))
                        .font(Theme.Typography.metricSmall)
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                .padding(Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(isKeep ? Theme.Palette.accentSubtle : Color.clear)
                )
            }
        }
    }

    private func modificationText(_ item: LargeFileEntry) -> String {
        guard let date = item.modificationDate else { return "Data de modificação indisponível" }
        return "Modificado em \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Rodapé de seleção

    private var selectionFooter: some View {
        HStack(spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.selectedCount == 0
                     ? "Nenhuma cópia marcada"
                     : "\(model.selectedCount) \(model.selectedCount == 1 ? "cópia marcada" : "cópias marcadas") · \(ByteSizeFormatter.format(model.selectedTotalSize))")
                    .font(Theme.Typography.bodyLarge)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(footerDetail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }

            Spacer(minLength: Theme.Spacing.md)

            if !model.groupsWithoutKeeper.isEmpty {
                Badge("\(model.groupsWithoutKeeper.count) \(model.groupsWithoutKeeper.count == 1 ? "grupo sem cópia" : "grupos sem cópia")", color: Theme.Palette.danger)
            }

            if model.isRemoving {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Removendo as cópias marcadas…")
                        .font(Theme.Typography.bodyLarge)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            } else {
                Button("Revisar e remover") { model.beginRemoval() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canRunRemoval)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface)
    }

    private var footerDetail: String {
        if model.selectedCount == 0 {
            return "Por padrão, cada grupo preserva a cópia mais antiga. Você pode mudar isso copiando uma ou mais."
        }
        if !model.groupsWithoutKeeper.isEmpty {
            return "Alguns grupos ficarão sem nenhuma cópia depois da remoção. Confira a confirmação."
        }
        return "Cada grupo marcado mantém ao menos uma cópia intacta. A remoção as envia para a Lixeira."
    }

    // MARK: - Confirmação

    private var removalMessage: String {
        var text = "\(model.pendingRemoval.count) \(model.pendingRemoval.count == 1 ? "cópia será movida" : "cópias serão movidas") para a Lixeira, de onde você pode restaurá-las. As cópias preservadas continuam no lugar."

        let risky = model.groupsWithoutKeeper
        if !risky.isEmpty {
            let names = risky.prefix(3).map { $0.items.first?.displayName ?? $0.digest.prefix(8).description }.joined(separator: ", ")
            let extra = risky.count > 3 ? " e mais \(risky.count - 3)" : ""
            text += " Atenção: \(names)\(extra) ficará\(risky.count == 1 ? "" : "ão") sem nenhuma cópia depois desta remoção. Se o conteúdo importar, cancele e revise a seleção."
        }

        return text
    }

    // MARK: - Apoio

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

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}
