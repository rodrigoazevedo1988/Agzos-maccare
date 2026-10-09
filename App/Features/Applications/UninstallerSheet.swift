import MacCareCore
import Observation
import SwiftUI

/// ## Folha de desinstalação
///
/// Mostra o aplicativo, os residuais encontrados e deixa o usuário escolher o
/// que vai para a Lixeira. Nada é removido antes de duas confirmações: a
/// seleção e, depois, o pedido explícito.
///
/// ## Três coisas que esta folha é obrigada a mostrar
///
/// 1. **O aviso de cada residual.** `LeftoverArtifact.warning` existe porque
///    "cache" e "documentos criados por você" são coisas muito diferentes, e o
///    usuário precisa dessa diferença antes de confirmar, não depois.
/// 2. **A confiança da associação.** Identificador exato, prefixo ou
///    localização conhecida não são a mesma prova. Os grupos são exibidos por
///    `Confidence`, e só o que é `certain` vem marcado.
/// 3. **O que o motor de segurança vai recusar.** O escopo autorizado padrão do
///    MacCare cobre caches e logs — não `/Applications`. A folha avalia cada
///    item com o `PathGuard` **antes** da confirmação, para não prometer uma
///    desinstalação que a execução vai recusar item a item.
struct UninstallerSheet: View {

    let application: ApplicationEntry
    let environment: AppEnvironment
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: UninstallerModel

    init(
        application: ApplicationEntry,
        environment: AppEnvironment,
        onFinished: @escaping () -> Void
    ) {
        self.application = application
        self.environment = environment
        self.onFinished = onFinished
        _model = State(initialValue: UninstallerModel(application: application, environment: environment))
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            header

            Divider().overlay(Theme.Palette.separator)

            if let result = model.result {
                resultView(result)
            } else {
                review
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Theme.Palette.canvas)
        .task {
            model.load()
        }
        .confirmationDialog(
            "Mover \(model.selectedCandidates.count) item(ns) para a Lixeira?",
            isPresented: $model.requestsStandardConfirmation,
            titleVisibility: .visible
        ) {
            confirmButton
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text(model.standardConfirmationMessage)
        }
        .alert(
            "Estes itens podem conter dados seus",
            isPresented: $model.requestsReinforcedConfirmation
        ) {
            confirmButton
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text(model.reinforcedConfirmationMessage)
        }
    }

    // MARK: - Cabeçalho

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text("Desinstalar \(application.name)")
                    .font(Theme.Typography.titleLarge)
                    .foregroundStyle(Theme.Palette.primaryText)

                Spacer(minLength: Theme.Spacing.md)

                Button("Fechar", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: Theme.Spacing.sm) {
                Text(application.versionSummary)
                Text("·")
                Text(application.sizeOnDisk.map { ByteSizeFormatter.format($0) } ?? "Tamanho não medido")
                if let identifier = application.bundleIdentifier {
                    Text("·")
                    Text(identifier)
                        .font(Theme.Typography.path)
                }
            }
            .font(Theme.Typography.bodySmall)
            .foregroundStyle(Theme.Palette.secondaryText)

            PathLabel(application.url.path, lineLimit: 2)
        }
        .padding(Theme.Spacing.xl)
    }

    // MARK: - Revisão

    private var review: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if model.phase == .loading {
                        Card {
                            HStack(spacing: Theme.Spacing.md) {
                                ProgressView().controlSize(.small)
                                Text("Procurando arquivos residuais de \(application.name)…")
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                        }
                    } else {
                        if let notice = model.scopeNotice {
                            LimitationNotice(notice, severity: .warning)
                        }

                        if application.bundleIdentifier == nil {
                            LimitationNotice(
                                "Este aplicativo não declara um identificador de bundle. Sem ele, o MacCare não consegue associar arquivos residuais a este aplicativo com segurança — por isso, nada além do próprio bundle é listado.",
                                severity: .warning
                            )
                        }

                        bundleSection

                        if model.groups.isEmpty {
                            Card {
                                EmptyStateView(
                                    symbol: "shippingbox",
                                    title: "Nenhum residual encontrado",
                                    message: "Nenhum cache, preferência ou pasta de dados deste aplicativo foi localizado nos caminhos padrão do macOS. Apenas o bundle será movido para a Lixeira."
                                )
                            }
                        } else {
                            ForEach(model.groups) { group in
                                groupSection(group)
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.xl)
            }

            Divider().overlay(Theme.Palette.separator)

            footer
        }
    }

    // MARK: - Seção do bundle

    private var bundleSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Aplicativo",
                subtitle: "O bundle vai para a Lixeira. É reversível até você esvaziá-la."
            )

            if let bundle = model.bundleItem {
                Card(padding: Theme.Spacing.md) {
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        Image(systemName: "app.badge")
                            .font(Theme.Typography.bodyLarge)
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(application.name)
                                .font(Theme.Typography.titleSmall)
                                .foregroundStyle(Theme.Palette.primaryText)

                            Text(bundle.candidate.reason)
                                .font(Theme.Typography.bodySmall)
                                .foregroundStyle(Theme.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            if let consequence = bundle.candidate.consequence {
                                Text(consequence)
                                    .font(Theme.Typography.bodySmall)
                                    .foregroundStyle(Theme.Palette.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            PathLabel(application.url.path)

                            ScopeBadge(verdict: model.verdict(for: bundle))
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - Seção de residuais

    private func groupSection(_ group: UninstallerModel.LeftoverGroup) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Associação \(group.confidence.label.lowercased())",
                subtitle: groupSubtitle(group.confidence),
                actionLabel: model.isGroupFullySelected(group) ? "Desmarcar grupo" : "Marcar grupo",
                action: { model.toggle(group: group.confidence) }
            )

            Card(padding: Theme.Spacing.xs) {
                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        residualRow(item)
                        if item.id != group.items.last?.id {
                            Divider().overlay(Theme.Palette.separator)
                        }
                    }
                }
            }
        }
    }

    private func groupSubtitle(_ confidence: Confidence) -> String {
        switch confidence {
        case .certain:
            return "O caminho contém o identificador do aplicativo. Associação certa."
        case .likely:
            return "Caminho conhecido, mas o identificador não está no nome. Confira item a item."
        case .uncertain:
            return "Associação incerta. Nada deste grupo vem marcado."
        }
    }

    private func residualRow(_ item: UninstallerModel.CandidateItem) -> some View {
        let verdict = model.verdict(for: item)
        let removable = verdict.isAllowed

        return HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Toggle(
                "",
                isOn: Binding(
                    get: { model.selected.contains(item.candidate.id) },
                    set: { model.setSelection($0, for: item.candidate) }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!removable)
            .help(removable ? "Incluir ou retirar da desinstalação" : "Fora do escopo autorizado")

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(item.candidate.displayName)
                        .font(Theme.Typography.bodyLarge)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .lineLimit(1)

                    if let artifact = item.artifact {
                        Badge(artifact.association.title, color: tint(for: artifact.association.confidence))
                    }

                    Spacer(minLength: Theme.Spacing.sm)

                    Text(item.candidate.sizeOnDisk.map { ByteSizeFormatter.format($0) } ?? "Não medido")
                        .font(Theme.Typography.metricSmall)
                        .foregroundStyle(item.candidate.sizeOnDisk == nil ? Theme.Palette.unavailable : Theme.Palette.secondaryText)
                        .monospacedDigit()
                }

                Text(item.candidate.reason)
                    .font(Theme.Typography.bodySmall)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let warning = item.artifact?.warning {
                    HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.Palette.warning)
                            .padding(.top, 2)

                        Text(warning)
                            .font(Theme.Typography.bodySmall)
                            .foregroundStyle(Theme.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                PathLabel(item.candidate.url.path)

                ScopeBadge(verdict: verdict)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .opacity(removable ? 1 : 0.65)
    }

    private func tint(for confidence: Confidence) -> Color {
        switch confidence {
        case .certain: return Theme.Palette.success
        case .likely: return Theme.Palette.warning
        case .uncertain: return Theme.Palette.unavailable
        }
    }

    // MARK: - Rodapé

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(model.selectionSummary)
                .font(Theme.Typography.bodySmall)
                .foregroundStyle(Theme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Spacing.md) {
                Text("Estratégia: \(RemovalStrategy.moveToTrash.label) — reversível")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)

                Spacer(minLength: Theme.Spacing.md)

                Button("Cancelar", role: .cancel, action: dismiss.callAsFunction)
                    .controlSize(.large)

                PrimaryActionButton(
                    "Mover para a Lixeira",
                    symbol: "trash",
                    isBusy: model.phase == .executing
                ) {
                    model.requestConfirmation()
                }
                .disabled(model.cannotProceed)
            }
        }
        .padding(Theme.Spacing.xl)
        .background(Theme.Palette.surface)
    }

    private var confirmButton: some View {
        Button("Mover para a Lixeira", role: .destructive) {
            model.execute()
        }
    }

    // MARK: - Resultado

    private func resultView(_ outcome: UninstallerModel.Outcome) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: outcome.isFullySuccessful ? "checkmark.circle" : "exclamationmark.triangle")
                                    .font(Theme.Typography.titleMedium)
                                    .foregroundStyle(outcome.isFullySuccessful ? Theme.Palette.success : Theme.Palette.warning)

                                Text(outcome.headline)
                                    .font(Theme.Typography.titleMedium)
                                    .foregroundStyle(Theme.Palette.primaryText)
                            }

                            Text(outcome.detail)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            if outcome.releasedSize > 0 {
                                Text("Espaço confirmado na Lixeira: \(ByteSizeFormatter.format(outcome.releasedSize))")
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Palette.primaryText)
                            }
                        }
                    }

                    if !outcome.failures.isEmpty {
                        LimitationNotice(
                            "\(outcome.failures.count) item(ns) não foram removidos. O motivo de cada um está abaixo — a recusa do motor de segurança é uma proteção funcionando, não uma falha.",
                            severity: .warning
                        )

                        Card(padding: Theme.Spacing.xs) {
                            VStack(spacing: 0) {
                                ForEach(outcome.failures) { failure in
                                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                        Text(failure.name)
                                            .font(Theme.Typography.bodyLarge)
                                            .foregroundStyle(Theme.Palette.primaryText)
                                        Text(failure.reason)
                                            .font(Theme.Typography.bodySmall)
                                            .foregroundStyle(Theme.Palette.secondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                        PathLabel(failure.path)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(Theme.Spacing.md)

                                    if failure.id != outcome.failures.last?.id {
                                        Divider().overlay(Theme.Palette.separator)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.xl)
            }

            Divider().overlay(Theme.Palette.separator)

            HStack {
                Spacer(minLength: 0)

                PrimaryActionButton("Concluir", symbol: "checkmark", action: finish)
            }
            .padding(Theme.Spacing.xl)
            .background(Theme.Palette.surface)
        }
    }

    private func finish() {
        onFinished()
        dismiss()
    }
}

// MARK: - Etiqueta de escopo

/// Traduz o veredito do `PathGuard` em texto.
///
/// Existe porque o escopo padrão do MacCare **não** cobre `/Applications`: sem
/// esta etiqueta, o usuário confirmaria uma desinstalação que a execução
/// recusaria item a item, e o relatório mostraria falhas em vez de uma
/// explicação.
private struct ScopeBadge: View {

    let verdict: PathVerdict

    private var isAllowed: Bool { verdict.isAllowed }

    private var title: String {
        guard let code = verdict.deniedCode else { return "Dentro do escopo autorizado" }
        switch code {
        case .outsideAllowedScope:
            return "Fora do escopo autorizado"
        case .symlinkEscapesScope:
            return "Link simbólico fora do escopo"
        case .protectedSystemPath, .applicationRootDirectory, .ownApplicationBundle, .homeDirectoryItself, .volumeOrTopLevelDirectory:
            return "Protegido pelo MacCare"
        default:
            return "Recusado"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: isAllowed ? "checkmark.shield" : "lock")
                .font(Theme.Typography.micro)
                .foregroundStyle(isAllowed ? Theme.Palette.success : Theme.Palette.warning)
                .padding(.top, 2)

            Text(isAllowed ? title : "\(title). \(verdict.deniedCode?.explanation ?? "")")
                .font(Theme.Typography.caption)
                .foregroundStyle(isAllowed ? Theme.Palette.tertiaryText : Theme.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Estado da desinstalação

/// ## Estado da folha de desinstalação
///
/// A folha **não** decide o que é seguro apagar: `Uninstaller` encontra e
/// classifica, e `isPreselectedByDefault` diz o que vem marcado. Este modelo
/// cuida do que é decisão de interface — agrupar, deixar o usuário escolher,
/// mostrar o que o motor de segurança vai recusar e exigir a confirmação.
///
/// A remoção em si só existe dentro de `environment.performCleanup`, que
/// reconfirma cada caminho no momento da execução.
@Observable
@MainActor
final class UninstallerModel {

    enum Phase: Equatable {
        case loading
        case review
        case executing
    }

    /// Um item da lista: o candidato que vai para a limpeza e, quando existe,
    /// o artefato que o originou — de onde vêm o aviso e o tipo de associação.
    struct CandidateItem: Identifiable {
        let candidate: CleanupCandidate
        let artifact: LeftoverArtifact?

        var id: UUID { candidate.id }
    }

    /// Residuais agrupados pelo nível de confiança da associação.
    struct LeftoverGroup: Identifiable {
        let confidence: Confidence
        let items: [CandidateItem]

        var id: Confidence { confidence }
    }

    /// Item que a execução não conseguiu remover, com o motivo.
    struct Failure: Identifiable {
        let url: URL
        let reason: String

        var id: String { url.path }
        var name: String {
            let last = url.lastPathComponent
            return last.isEmpty ? url.path : last
        }
        var path: String { url.path }
    }

    /// Resultado da execução, em linguagem de tela.
    struct Outcome {
        let headline: String
        let detail: String
        let releasedSize: Int64
        let failures: [Failure]
        let isFullySuccessful: Bool

        init(report: RemovalReport) {
            headline = report.isFullySuccessful
                ? "Desinstalação concluída"
                : "Remoção concluída em parte"
            detail = report.summary + " Os itens ignorados pelo motor de segurança continuam onde estavam — nada foi forçado."
            releasedSize = report.accounting.releasedConfirmed
            failures = report.failed
                .map { Failure(url: $0.url, reason: $0.reason ?? "Falha sem detalhe informado.") }
                + report.skipped
                    .map { Failure(url: $0.url, reason: $0.reason ?? "Ignorado pelas regras de segurança.") }
            isFullySuccessful = report.isFullySuccessful
        }

        init(error: Error) {
            headline = "A desinstalação não foi executada"
            detail = error.localizedDescription
            releasedSize = 0
            failures = []
            isFullySuccessful = false
        }
    }

    // MARK: - Estado

    private let application: ApplicationEntry
    private let environment: AppEnvironment

    private(set) var phase: Phase = .loading
    private(set) var bundleItem: CandidateItem?
    private(set) var groups: [LeftoverGroup] = []
    private(set) var result: Outcome?

    /// Identificadores dos candidatos marcados. `CleanupCandidate.id` é um
    /// `UUID` criado pelo núcleo a cada chamada, o que serve bem: a seleção
    /// pertence a esta execução da folha, e uma releitura da lista de
    /// residuais começa do zero em vez de reaproveitar marcas antigas.
    private(set) var selected: Set<UUID> = []

    var requestsStandardConfirmation = false
    var requestsReinforcedConfirmation = false

    private var hasLoaded = false
    private var loadTask: Task<Void, Never>?

    init(application: ApplicationEntry, environment: AppEnvironment) {
        self.application = application
        self.environment = environment
    }

    // MARK: - Carga

    /// Encontra os residuais sem tocar em nada.
    func load() {
        guard !hasLoaded, loadTask == nil else { return }
        hasLoaded = true

        let application = self.application
        loadTask = Task { [weak self] in
            let payload = await Task.detached(priority: .userInitiated) { () -> Payload in
                let uninstaller = Uninstaller()
                return Payload(
                    leftovers: uninstaller.findLeftovers(for: application),
                    candidates: uninstaller.removalCandidates(for: application)
                )
            }.value

            guard let self, !Task.isCancelled else { return }
            self.apply(payload)
            self.loadTask = nil
        }
    }

    /// Resultado bruto do núcleo, montado fora do isolate principal.
    private struct Payload: Sendable {
        let leftovers: [LeftoverArtifact]
        let candidates: [CleanupCandidate]
    }

    private func apply(_ payload: Payload) {
        // O dicionário liga cada candidato ao artefato que o originou. É o que
        // permite mostrar o `warning` e o tipo de associação — informações que
        // `CleanupCandidate` transporta parcialmente, como texto.
        let artifacts = Dictionary(
            payload.leftovers.map { ($0.url.standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let items = payload.candidates.map { candidate in
            CandidateItem(candidate: candidate, artifact: artifacts[candidate.url.standardizedFileURL.path])
        }

        let bundlePath = application.url.standardizedFileURL.path
        bundleItem = items.first { $0.candidate.url.standardizedFileURL.path == bundlePath }

        let leftovers = items.filter { $0.candidate.id != bundleItem?.candidate.id }
        groups = Dictionary(grouping: leftovers, by: { $0.candidate.confidence })
            .map { LeftoverGroup(confidence: $0.key, items: sortBySize($0.value)) }
            .sorted { $0.confidence > $1.confidence }

        // A seleção inicial vem do núcleo: `certain` e sem confirmação
        // reforçada. Itens fora do escopo entram desmarcados e com a
        // marcação desabilitada — um item marcado que não pode ser removido
        // seria uma promessa falsa.
        selected = Set(
            items
                .filter { $0.candidate.isPreselectedByDefault }
                .filter { verdict(for: $0.candidate).isAllowed }
                .map(\.candidate.id)
        )

        phase = .review
    }

    /// Maior primeiro; sem tamanho medido por último, porque tamanho ausente
    /// não é tamanho zero.
    private func sortBySize(_ items: [CandidateItem]) -> [CandidateItem] {
        items.sorted { lhs, rhs in
            switch (lhs.candidate.sizeOnDisk, rhs.candidate.sizeOnDisk) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.candidate.url.path < rhs.candidate.url.path
            }
        }
    }

    // MARK: - Escopo

    /// Veredito do motor de segurança para um item.
    ///
    /// É uma prévia de interface, não uma autorização: `performCleanup`
    /// revalida cada caminho no momento da execução. Mostrar o veredito antes
    /// da confirmação evita que o usuário concorde com algo que a execução vai
    /// recusar — o que, no escopo padrão, inclui o próprio bundle em
    /// `/Applications`.
    func verdict(for item: CandidateItem) -> PathVerdict {
        verdict(for: item.candidate)
    }

    func verdict(for candidate: CleanupCandidate) -> PathVerdict {
        environment.pathGuard.evaluate(candidate.url)
    }

    /// Aviso único sobre itens que o escopo atual não cobre.
    var scopeNotice: String? {
        let denied = allItems.filter { !verdict(for: $0).isAllowed }
        guard !denied.isEmpty else { return nil }

        let bundleDenied = bundleItem.map { !verdict(for: $0).isAllowed } ?? false
        var text = "\(denied.count) item(ns) desta lista estão fora do escopo de análise autorizado"
        text += bundleDenied ? ", incluindo o bundle do aplicativo. " : ". "
        text += "O MacCare não amplia o próprio escopo sozinho: autorize a pasta do aplicativo e a pasta de dados em Ajustes, ou remova o que falta pelo Finder."
        return text
    }

    // MARK: - Seleção

    var allItems: [CandidateItem] {
        ([bundleItem].compactMap { $0 }) + groups.flatMap(\.items)
    }

    /// Candidatos marcados, na ordem em que aparecem: bundle primeiro, depois
    /// os grupos do mais confiável para o menos confiável.
    var selectedCandidates: [CleanupCandidate] {
        var result: [CleanupCandidate] = []
        if let bundleItem, selected.contains(bundleItem.candidate.id) {
            result.append(bundleItem.candidate)
        }
        for group in groups {
            result.append(contentsOf: group.items
                .filter { selected.contains($0.candidate.id) }
                .map(\.candidate))
        }
        return result
    }

    var selectedSize: Int64 {
        selectedCandidates.reduce(into: Int64(0)) { partial, item in
            if let size = item.sizeOnDisk { partial += size }
        }
    }

    var hasUnmeasuredSelection: Bool {
        selectedCandidates.contains { $0.sizeOnDisk == nil }
    }

    func setSelection(_ isSelected: Bool, for candidate: CleanupCandidate) {
        if isSelected {
            selected.insert(candidate.id)
        } else {
            selected.remove(candidate.id)
        }
    }

    /// Só itens liberados pelo escopo podem ser marcados — a chave está
    /// desabilitada na interface e aqui o motivo é o mesmo.
    func toggle(group: Confidence) {
        guard let items = groups.first(where: { $0.confidence == group })?.items else { return }
        if isGroupFullySelected(items) {
            for item in items { selected.remove(item.candidate.id) }
        } else {
            for item in items where verdict(for: item).isAllowed {
                selected.insert(item.candidate.id)
            }
        }
    }

    func isGroupFullySelected(_ group: LeftoverGroup) -> Bool {
        isGroupFullySelected(group.items)
    }

    private func isGroupFullySelected(_ items: [CandidateItem]) -> Bool {
        let usable = items.filter { verdict(for: $0).isAllowed }
        guard !usable.isEmpty else { return false }
        return usable.allSatisfy { selected.contains($0.candidate.id) }
    }

    // MARK: - Resumo e confirmação

    var selectionSummary: String {
        let count = selectedCandidates.count
        guard count > 0 else {
            return "Nada selecionado. Escolha ao menos um item para continuar."
        }

        // A soma ignora o que não pôde ser medido, e a frase diz isso. Somar
        // zero para um item desconhecido daria ao usuário uma estimativa
        // melhor do que ele realmente tem.
        let measured = hasUnmeasuredSelection
            ? "\(ByteSizeFormatter.format(selectedSize)) medidos, sem contar itens cujo tamanho não pôde ser medido."
            : "\(ByteSizeFormatter.format(selectedSize))."

        return "\(count) item(ns) selecionado(s) · \(measured)"
    }

    /// `true` quando a seleção inclui itens que podem conter o que o usuário
    /// criou.
    ///
    /// A regra espelha `Uninstaller.warning(for:isDirectory:application:)` no
    /// núcleo: `Application Support` e `Containers` é onde aplicativos guardam
    /// documentos, projetos e sessões. Não é heurística de nome de arquivo — é
    /// a mesma classificação que já produz o aviso exibido na lista.
    private static func holdsUserData(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/Application Support/") || path.contains("/Containers/")
    }

    private var selectedUserDataItems: [CleanupCandidate] {
        selectedCandidates.filter { Self.holdsUserData($0.url) }
    }

    var needsReinforcedConfirmation: Bool {
        !selectedUserDataItems.isEmpty
    }

    var cannotProceed: Bool {
        phase == .executing || selectedCandidates.isEmpty
    }

    func requestConfirmation() {
        guard !cannotProceed else { return }
        if needsReinforcedConfirmation {
            requestsReinforcedConfirmation = true
        } else {
            requestsStandardConfirmation = true
        }
    }

    var standardConfirmationMessage: String {
        let count = selectedCandidates.count
        return "\(count) item(ns) serão movidos para a Lixeira, juntos com o aplicativo \(application.name). "
            + "Nada é excluído definitivamente: enquanto estiverem na Lixeira, dá para restaurar. "
            + "Depois que você esvaziar a Lixeira, a remoção é definitiva."
    }

    var reinforcedConfirmationMessage: String {
        let items = selectedUserDataItems
        let names = items
            .map(\.displayName)
            .prefix(6)
            .joined(separator: ", ")
        let extra = items.count > 6 ? " e mais \(items.count - 6) item(ns)" : ""

        return "A seleção inclui \(items.count) item(ns) que podem conter arquivos, projetos ou documentos criados por você: \(names)\(extra). "
            + "Esses dados não são regenerados pelo aplicativo e não existe cópia em nenhum outro lugar. "
            + "Se você não tiver certeza do que está guardado ali, cancele e revise cada item."
    }

    // MARK: - Execução

    /// Executa a remoção pela única porta disponível.
    ///
    /// `performCleanup` reconfirma a seleção, revalida cada caminho e registra
    /// a operação no histórico. Nenhum arquivo é apagado por outro caminho.
    func execute() {
        let candidates = selectedCandidates
        guard !candidates.isEmpty else { return }

        requestsStandardConfirmation = false
        requestsReinforcedConfirmation = false
        phase = .executing

        let environment = self.environment
        Task { [weak self] in
            guard let self else { return }
            do {
                let (report, _) = try await environment.performCleanup(
                    candidates: candidates,
                    strategy: .moveToTrash,
                    kind: .applicationRemoval
                )
                self.result = Outcome(report: report)
            } catch {
                self.result = Outcome(error: error)
            }
            self.phase = .review
        }
    }
}
