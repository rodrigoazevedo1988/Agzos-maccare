import AppKit
import Foundation
import MacCareCore
import SwiftUI
import UniformTypeIdentifiers

/// ## Arquivos grandes
///
/// Esta tela faz duas coisas e recusa-se a fazer uma terceira: **medir** e
/// **listar**. Ela não decide o que é lixo.
///
/// Arquivo grande é uma característica, não um defeito. Um vídeo de 40 GB pode
/// ser o único exemplar de um projeto; um cache de 30 GB pode ser regenerado em
/// dois minutos. O app não tem como saber qual é qual — e por isso cada remoção
/// aqui é uma ação isolada, marcada pelo usuário e confirmada antes de
/// acontecer.
struct LargeFilesView: View {

    let environment: AppEnvironment
    @State private var model = LargeFilesModel()

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    folderCard
                    filtersCard
                    errorBanner

                    if model.isScanning {
                        ScanProgressCard(
                            title: "Procurando arquivos grandes",
                            progress: model.progress,
                            onCancel: { model.cancelScan() }
                        )
                    }

                    if model.wasCancelled {
                        LimitationNotice(
                            "A varredura foi cancelada. Nenhum resultado parcial é exibido, para não sugerir um inventário incompleto.",
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

            if !model.visibleEntries.isEmpty {
                Divider().overlay(Theme.Palette.separator)
                reviewFooter
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
            Text("Mover para a Lixeira?"),
            isPresented: $model.showRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Mover \(model.pendingRemoval.count) \(model.pendingRemoval.count == 1 ? "item" : "itens") para a Lixeira") {
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
                    "Pastas a varrer",
                    subtitle: "O MacCare procura apenas onde você mandar. Nada é varrido ao abrir a tela."
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
                        .disabled(model.isScanning)

                    if !model.suggestedRoots.isEmpty {
                        Text("Sugestões:")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)

                        ForEach(model.suggestedRoots, id: \.self) { suggestion in
                            Button(suggestion.lastPathComponent) { model.addRoot(suggestion) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.isScanning)
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Filtros

    private var filtersCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader("Filtros", subtitle: "Valem apenas para a próxima varredura.")

                HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Tamanho mínimo")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                        Picker("Tamanho mínimo", selection: $model.minimumSize) {
                            ForEach(LargeFilesModel.SizeThreshold.allCases) { threshold in
                                Text(threshold.title).tag(threshold)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Extensões")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                        TextField("Todas", text: $model.extensionText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                        Text("Separe por vírgula, sem ponto. Ex.: mov, mp4, zip")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Toggle("Incluir diretórios", isOn: $model.includeDirectories)
                            .toggleStyle(.checkbox)
                            .font(Theme.Typography.body)
                        Text("Mostra também pastas volumosas, e não só arquivos.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                Divider().overlay(Theme.Palette.separator)

                HStack(alignment: .center, spacing: Theme.Spacing.md) {
                    Toggle("Modificado depois de", isOn: $model.filtersByDate)
                        .toggleStyle(.checkbox)
                        .font(Theme.Typography.body)

                    DatePicker(
                        "Modificado depois de",
                        selection: $model.modifiedAfter,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .disabled(!model.filtersByDate)

                    Spacer(minLength: Theme.Spacing.md)

                    PrimaryActionButton("Varrer", symbol: "doc.text.magnifyingglass", isBusy: model.isScanning) {
                        model.startScan(environment: environment)
                    }
                    .disabled(!model.canScan)
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
        if model.result == nil && !model.isScanning {
            EmptyStateView(
                symbol: "folder",
                title: "Nenhuma varredura executada",
                message: "Escolha uma pasta, ajuste os filtros e execute a varredura. Os arquivos ficam listados para você revisar — nenhum é removido automaticamente."
            )
        } else if let result = model.result, result.files.isEmpty {
            EmptyStateView(
                symbol: "checkmark.circle",
                title: "Nada encontrado com esses filtros",
                message: "A varredura terminou e nenhum item correspondeu aos critérios. Tente reduzir o tamanho mínimo ou aceitar mais extensões."
            )
        } else if !model.visibleEntries.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(
                    "Arquivos encontrados",
                    subtitle: "\(model.visibleEntries.count) itens · \(ByteSizeFormatter.format(model.totalSize)) no total",
                    actionLabel: model.reviewIDs.isEmpty ? nil : "Limpar revisão"
                ) {
                    model.clearReview()
                }

                if model.result?.progress.wasTruncated == true {
                    LimitationNotice(
                        "A varredura atingiu o limite de tempo ou de arquivos e parou antes do fim. A lista acima está incompleta — aumente o escopo em Ajustes para uma varredura mais profunda.",
                        severity: .warning
                    )
                }

                let inaccessible = model.result?.inaccessiblePaths ?? []
                if !inaccessible.isEmpty {
                    LimitationNotice(
                        "\(inaccessible.count) \(inaccessible.count == 1 ? "caminho não pôde ser lido" : "caminhos não puderam ser lidos") e não entram no total. Sem a autorização correspondente, o macOS não deixa o MacCare ler o conteúdo.",
                        severity: .warning
                    )
                }

                if model.filtersChanged {
                    LimitationNotice(
                        "Os filtros mudaram depois desta varredura. Os resultados na tela ainda refletem os filtros anteriores — execute a varredura de novo para aplicar os novos.",
                        severity: .information
                    )
                }

                HStack {
                    Text("Ordenar por")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                    Picker("Ordenar por", selection: $model.sort) {
                        ForEach(LargeFilesModel.Sort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Spacer(minLength: 0)
                }

                LazyVStack(spacing: Theme.Spacing.xs) {
                    ForEach(model.visibleEntries) { entry in
                        LargeFileRow(
                            entry: entry,
                            isInReview: model.isInReview(entry),
                            isBusy: model.isRemoving,
                            onReveal: { reveal(entry.url) },
                            onToggleReview: { model.toggleReview(entry) },
                            onRemove: { model.beginRemoval(entries: [entry]) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Rodapé de revisão

    private var reviewFooter: some View {
        HStack(spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.reviewIDs.isEmpty
                     ? "Nenhum item na lista de revisão"
                     : "\(model.reviewEntries.count) \(model.reviewEntries.count == 1 ? "item na lista de revisão" : "itens na lista de revisão") · \(ByteSizeFormatter.format(model.reviewTotalSize))")
                    .font(Theme.Typography.bodyLarge)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text("Marque itens com o botão de revisão e remova apenas o que você reconhece. Arquivo grande não é lixo.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }

            Spacer(minLength: Theme.Spacing.md)

            if model.isRemoving {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Movendo a seleção para a Lixeira…")
                        .font(Theme.Typography.bodyLarge)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            } else {
                Button("Mover seleção para a Lixeira") {
                    model.beginRemoval(entries: model.reviewEntries)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.reviewEntries.isEmpty || model.isRemoving)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface)
    }

    // MARK: - Confirmação

    private var removalMessage: String {
        guard !model.pendingRemoval.isEmpty else { return "" }
        let list = model.pendingRemoval.prefix(4).map(\.displayName).joined(separator: ", ")
        let extra = model.pendingRemoval.count > 4 ? " e mais \(model.pendingRemoval.count - 4)" : ""
        return "\(list)\(extra) — total de \(ByteSizeFormatter.format(model.pendingRemoval.reduce(0) { $0 + $1.sizeOnDisk })). Serão movidos para a Lixeira, de onde você pode restaurá-los. Confira o nome de cada um: o MacCare não sabe se algum deles é o único exemplar de algo importante."
    }

    // MARK: - Apoio

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}

// MARK: - Linha de arquivo

private struct LargeFileRow: View {

    let entry: LargeFileEntry
    let isInReview: Bool
    let isBusy: Bool
    let onReveal: () -> Void
    let onToggleReview: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.secondaryText)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(entry.displayName)
                        .font(Theme.Typography.bodyLarge)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if entry.isDirectory {
                        Badge("Pasta", color: Theme.Palette.secondaryText)
                    }

                    if entry.isInSyncedFolder {
                        Badge("Sincronizado", color: Theme.Palette.accent)
                    }
                }

                PathLabel(abbreviated(entry.url))
            }

            Spacer(minLength: Theme.Spacing.md)

            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteSizeFormatter.format(entry.sizeOnDisk))
                    .font(Theme.Typography.metricSmall)
                    .foregroundStyle(Theme.Palette.primaryText)
                if let date = entry.modificationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                } else {
                    // Sem data legível não existe "muito antigo": mostrar
                    // qualquer data aqui seria inventar dado.
                    Text("Data de modificação indisponível")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.unavailable)
                }
            }

            HStack(spacing: Theme.Spacing.xs) {
                Button(action: onReveal) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(Theme.Typography.bodySmall)
                }
                .buttonStyle(.bordered)
                .help("Revelar no Finder")

                Button(isInReview ? "Na revisão" : "Revisar", action: onToggleReview)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)

                Button("Remover", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(isInReview ? Theme.Palette.accentSubtle : Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 0.5)
        )
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}
