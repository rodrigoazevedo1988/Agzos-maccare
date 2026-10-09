import Foundation
import MacCareCore
import SwiftUI
import UniformTypeIdentifiers

/// ## Analisador de armazenamento
///
/// Esta tela é a mais fácil de enganar, porque "quanto ocupa" tem três
/// respostas diferentes e o usuário espera que elas concordem. Elas não
/// concordam, e o app diz isso em vez de escolher a que parece mais bonita:
///
/// - **O que o disco responde** (`VolumeUsage`): capacidade e espaço livre.
/// - **O que foi analisado** (`StorageNode.sizeOnDisk`): espaço ocupado, isto
///   é, blocos efetivamente alocados — que pode ser maior que o conteúdo do
///   arquivo por causa dos blocos de contêiner.
/// - **O que não foi autorizado**: tudo que o macOS não deixou ler, marcado
///   por `isPartial` e declarado como estimativa.
///
/// A navegação é por barras recursivas dentro de um `OutlineGroup`: clicar em
/// um nó expande ou recolhe. Um treemap seria mais bonito e menos confiável
/// para leitura — e aqui a pergunta é "quanto", não "como é o desenho".
struct StorageAnalyzerView: View {

    let environment: AppEnvironment
    @State private var model = StorageAnalyzerModel()

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                controlCard
                errorBanner

                if let snapshot = model.snapshot {
                    volumeSection(snapshot)
                }

                treeSection
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.Palette.canvas)
        .fileImporter(
            isPresented: $model.isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { outcome in
            switch outcome {
            case .success(let urls):
                if let url = urls.first { model.setRoot(url) }
            case .failure(let error):
                model.errorMessage = "Não foi possível abrir o seletor de pastas: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Controles

    private var controlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(
                    "O que analisar",
                    subtitle: "A contagem de tamanhos percorre o disco e leva tempo. Nada é medido ao abrir a tela."
                )

                HStack(alignment: .center, spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Pasta")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                        if let root = model.root {
                            PathLabel(abbreviated(root))
                        } else {
                            Text("Nenhuma pasta escolhida")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.warning)
                        }
                    }

                    Spacer(minLength: Theme.Spacing.md)

                    Button("Escolher pasta…") { model.isChoosingFolder = true }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                    Picker("Profundidade", selection: $model.depth) {
                        ForEach(StorageAnalyzerModel.Depth.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)

                    PrimaryActionButton("Analisar", symbol: "internaldrive", isBusy: model.isLoadingTree) {
                        model.loadTree(environment: environment)
                    }
                    .disabled(!model.canAnalyze)
                }

                if model.isLoadingTree {
                    HStack(spacing: Theme.Spacing.md) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("Contando tamanhos. Em discos grandes, isso pode levar alguns minutos.")
                            .font(Theme.Typography.bodySmall)
                            .foregroundStyle(Theme.Palette.secondaryText)
                        Spacer(minLength: 0)
                        Button("Cancelar") { model.cancelTreeLoading() }
                            .buttonStyle(.bordered)
                    }
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

    // MARK: - Volume

    @ViewBuilder
    private func volumeSection(_ snapshot: StorageAnalyzerModel.VolumeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Visão geral do volume",
                subtitle: "Leitura em \(snapshot.capturedAt.formatted(date: .omitted, time: .shortened))",
                actionLabel: "Atualizar"
            ) {
                model.refreshVolume()
            }

            switch snapshot.volume {
            case .available(let volume):
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Theme.Metrics.tileMinWidth), spacing: Theme.Spacing.md)],
                    spacing: Theme.Spacing.md
                ) {
                    StatTile(
                        "Espaço livre",
                        symbol: "externaldrive.badge.checkmark",
                        tint: freeTint(volume),
                        value: .available(ByteSizeFormatter.format(volume.availableCapacity)),
                        caption: "\(ByteSizeFormatter.percent(freeFraction(volume), fractionDigits: 1)) de \(volume.volumeName)"
                    )

                    StatTile(
                        "Em uso",
                        symbol: "internaldrive",
                        tint: Theme.Palette.accent,
                        value: .available(ByteSizeFormatter.format(volume.used)),
                        caption: "\(ByteSizeFormatter.percent(volume.usedFraction, fractionDigits: 1)) de \(ByteSizeFormatter.format(volume.totalCapacity))"
                    )

                    // Os dois blocos abaixo só existem quando a árvore foi
                    // construída. Antes disso não há nada a medir, e exibir
                    // qualquer valor aqui seria inventar.
                    if model.tree != nil {
                        StatTile(
                            "Analisado nesta pasta",
                            symbol: "sum",
                            tint: Theme.Palette.secondaryText,
                            value: .available(ByteSizeFormatter.format(model.analyzedSize)),
                            caption: "Espaço ocupado em disco, somado pasta por pasta."
                        )

                        StatTile(
                            "Nós estimados",
                            symbol: "questionmark.circle",
                            tint: model.partialNodeCount > 0 ? Theme.Palette.warning : Theme.Palette.secondaryText,
                            value: .available("\(model.partialNodeCount)"),
                            caption: model.partialNodeCount > 0
                                ? "Partes que o macOS não autorizou ler. O total é uma estimativa."
                                : "Nenhuma parte ficou sem leitura."
                        )
                    }
                }

            case .unavailable(let reason):
                LimitationNotice(
                    "Não foi possível ler a ocupação do volume: \(reason.explanation)",
                    severity: .warning
                )
            }
        }
    }

    /// `VolumeUsage` expõe `usedFraction`, mas não a fração livre — que é a
    /// que o usuário lê primeiro e a que decide a cor do indicador. Derivada
    /// aqui a partir da mesma capacidade, sem arredondar o resultado.
    private func freeFraction(_ volume: VolumeUsage) -> Double {
        guard volume.totalCapacity > 0 else { return 0 }
        return Double(volume.availableCapacity) / Double(volume.totalCapacity)
    }

    private func freeTint(_ volume: VolumeUsage) -> Color {
        let free = freeFraction(volume)
        if free < InsightThresholds.criticalFreeSpaceFraction { return Theme.Palette.danger }
        if free < InsightThresholds.lowFreeSpaceFraction { return Theme.Palette.warning }
        return Theme.Palette.success
    }

    // MARK: - Árvore

    @ViewBuilder
    private var treeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Onde o espaço está",
                subtitle: "A barra de cada item é a fatia dele dentro da pasta acima. Na hierarquia, clique para expandir ou recolher."
            )

            if model.isLoadingTree {
                Card {
                    HStack(spacing: Theme.Spacing.md) {
                        ProgressView().controlSize(.small)
                        Text("Contando tamanhos…")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
            } else if let tree = model.tree {
                partialNotice(tree)

                if tree.children.isEmpty {
                    EmptyStateView(
                        symbol: "folder",
                        title: "Pasta vazia ou ilegível",
                        message: "Não foi possível ler o conteúdo desta pasta. Sem a autorização correspondente, o macOS não deixa o MacCare listar o que há dentro."
                    )
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("Distribuição no nível atual")
                                .font(Theme.Typography.captionEmphasized)
                                .foregroundStyle(Theme.Palette.secondaryText)

                            ForEach(model.topLevelItems) { item in
                                NodeRow(
                                    node: item.node,
                                    parentSize: item.parentSize,
                                    showsPath: false
                                )
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("Hierarquia")
                                .font(Theme.Typography.captionEmphasized)
                                .foregroundStyle(Theme.Palette.secondaryText)

                            OutlineGroup(model.topLevelItems, children: \.children) { item in
                                NodeRow(
                                    node: item.node,
                                    parentSize: item.parentSize,
                                    showsPath: true
                                )
                            }
                        }
                    }
                }
            } else {
                EmptyStateView(
                    symbol: "internaldrive",
                    title: "Nenhuma análise executada",
                    message: "Escolha a pasta e conte os tamanhos. O MacCare mostra o espaço ocupado por pasta e por arquivo, e sinaliza tudo que o macOS não deixou ler.",
                    actionLabel: "Analisar agora"
                ) {
                    model.loadTree(environment: environment)
                }
            }
        }
    }

    /// A distinção entre "medido" e "estimado" precisa aparecer antes dos
    /// números, e não em uma nota de rodapé que ninguém lê.
    @ViewBuilder
    private func partialNotice(_ tree: StorageNode) -> some View {
        if tree.isPartial {
            LimitationNotice(
                "Os totais acima são estimativas. O macOS não autorizou a leitura de \(model.partialNodeCount) \(model.partialNodeCount == 1 ? "parte" : "partes") desta árvore — normalmente é falta de Acesso Total ao Disco. O que o MacCare mostra é o que conseguiu medir, nunca o que adivinhou.",
                severity: .warning
            )
        } else {
            LimitationNotice(
                "Todos os tamanhos são o espaço efetivamente ocupado em disco, que pode ser maior que o tamanho do arquivo por causa dos blocos alocados pelos contêineres. É por isso que os números aqui podem não bater com o \"tamanho\" que o Finder mostra.",
                severity: .information
            )
        }
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}

// MARK: - Linha da árvore

/// Uma linha com barra proporcional.
///
/// A barra representa a fatia do nó **dentro do pai**, não dentro do total
/// absoluto: é essa leitura — "isto é quase tudo o que está aqui" — que
/// responde à pergunta que a tela faz.
private struct NodeRow: View {

    let node: StorageNode
    let parentSize: Int64
    let showsPath: Bool

    private var fraction: Double {
        guard parentSize > 0, node.sizeOnDisk > 0 else { return 0 }
        return Double(node.sizeOnDisk) / Double(parentSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: node.children.isEmpty ? "doc" : "folder")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .frame(width: 16)

                Text(node.name)
                    .font(Theme.Typography.bodyLarge)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if node.isPartial {
                    Badge("Estimativa", color: Theme.Palette.warning)
                }

                Spacer(minLength: Theme.Spacing.md)

                Text(ByteSizeFormatter.format(node.sizeOnDisk))
                    .font(Theme.Typography.metricSmall)
                    .foregroundStyle(Theme.Palette.primaryText)

                Text(ByteSizeFormatter.percent(fraction))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .frame(width: 44, alignment: .trailing)
            }

            bar

            if showsPath {
                PathLabel(node.url.path)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.Palette.separator)

                // A fração zero ainda desenha um traço mínimo. Sem ele, um
                // item que ocupa pouco some da lista — e "não deu para
                // medir" precisa ser visível, não indistinguível de zero.
                Capsule(style: .continuous)
                    .fill(node.isPartial ? Theme.Palette.warning : Theme.Palette.accent)
                    .frame(width: max(2, proxy.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}
