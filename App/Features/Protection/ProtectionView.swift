import SwiftUI

/// ## Proteção
///
/// A tela se apresenta pelo que **não** é, antes de mostrar o que é. Um módulo
/// chamado "Proteção" que não diz que não é antivírus seria uma armadilha: o
/// usuário lê o nome, vê uma lista verde e conclui que o Mac está limpo.
///
/// Depois do aviso, a tela mostra o trabalho verificável — assinatura e
/// notarização de cada aplicativo — com as quatro classificações separadas e as
/// regras que dispararam. Nenhum item é removido, e nenhum ajuste de segurança
/// do macOS é alterado.
@MainActor
struct ProtectionView: View {

    @State private var model: ProtectionModel

    init(environment: AppEnvironment) {
        _model = State(wrappedValue: ProtectionModel(environment: environment))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                scopeNotice
                summaryTiles
                analysisControls
                rulesCatalogue
                reportList
                closingNotice
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.Palette.canvas)
    }

    // MARK: - Escopo declarado

    /// O aviso que abre a tela. Deliberadamente destacado: `warning`, card
    /// elevado e texto em corpo grande, não em rodapé de letra miúda.
    private var scopeNotice: some View {
        Card(elevated: true) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "checkmark.shield")
                        .font(Theme.Typography.titleMedium)
                        .foregroundStyle(Theme.Palette.warning)
                    Text("O MacCare não é um antivírus")
                        .font(Theme.Typography.titleLarge)
                        .foregroundStyle(Theme.Palette.primaryText)
                }

                LimitationNotice(
                    """
                    Este aplicativo não faz varredura de malware, não detecta ameaças, \
                    não monitora o Mac em tempo real e não substitui o Gatekeeper, o \
                    XProtect ou o Malwarebytes.

                    Consequência prática: nada encontrado aqui significa apenas ausência \
                    de detecção, e ausência de detecção não é garantia de segurança. \
                    Malware que o macOS ainda não conhece passa despercebido por \
                    qualquer verificação de assinatura.
                    """,
                    severity: .warning
                )

                Text("O que esta tela realmente verifica: a assinatura do código de cada aplicativo instalado, a identidade de quem o assinou e o registro desse código no serviço de notarização da Apple. É procedência declarada, não análise de comportamento.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Resumo

    private var summaryTiles: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Resultado da verificação",
                subtitle: model.analyzedAt.map {
                    "Verificado em \($0.formatted(date: .omitted, time: .shortened))"
                } ?? "Nenhuma verificação executada nesta sessão."
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Theme.Metrics.tileMinWidth), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                ForEach(ProtectionModel.Verdict.allCases) { verdict in
                    StatTile(
                        verdict.title,
                        symbol: verdict.symbolName,
                        tint: verdict.color,
                        value: .available("\(model.count(of: verdict))"),
                        caption: verdict.tileCaption
                    )
                }
            }

            // As quatro definições, por extenso. Uma tela que mostra quatro
            // números coloridos sem explicar a diferença entre eles obriga o
            // usuário a adivinhar o que significam.
            Card {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(ProtectionModel.Verdict.allCases) { verdict in
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Image(systemName: verdict.symbolName)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(verdict.color)
                                .frame(width: 16)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(verdict.longTitle)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Palette.primaryText)
                                Text(verdict.explanation)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Controles

    private var analysisControls: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    PrimaryActionButton(
                        "Verificar assinaturas",
                        symbol: "checkmark.shield",
                        isBusy: model.isAnalyzing
                    ) {
                        model.startAnalysis()
                    }
                    .disabled(model.isAnalyzing)

                    if model.isAnalyzing {
                        Button("Parar") { model.cancelAnalysis() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }

                    Spacer(minLength: 0)
                }

                if model.isAnalyzing {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        if let progress = model.progress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                            Text("Verificando \(model.analyzedCount) de \(model.totalCount) aplicativos…")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        } else {
                            HStack(spacing: Theme.Spacing.sm) {
                                ProgressView().controlSize(.small)
                                Text("Enumerando aplicativos instalados…")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                        }
                    }
                } else if model.wasInterrupted {
                    Text("Verificação interrompida. Os resultados parciais continuam na lista; execute novamente para completar.")
                        .font(Theme.Typography.bodySmall)
                        .foregroundStyle(Theme.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let errorMessage = model.errorMessage {
                    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.warning)
                            .padding(.top, 1)
                        Text(errorMessage)
                            .font(Theme.Typography.bodySmall)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Regras

    /// O catálogo: o conjunto fechado de regras, com o efeito de cada uma.
    ///
    /// Mostrar isto antes da lista é o que dá sentido aos rótulos. Sem ele,
    /// "Suspeito" é uma opinião; com ele, é o resultado de R-01 ou R-02, e o
    /// usuário pode concordar ou discordar do critério.
    private var rulesCatalogue: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Regras aplicadas",
                subtitle: "O MacCare avalia apenas estas condições, todas verificáveis. As que dispararem aparecem em cada aplicativo."
            )

            Card {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(ProtectionRule.catalogue) { rule in
                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            Text(rule.code)
                                .font(Theme.Typography.path)
                                .foregroundStyle(Theme.Palette.tertiaryText)
                                .frame(width: 44, alignment: .leading)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.title)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Palette.primaryText)
                                Text(rule.summary)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: Theme.Spacing.sm)

                            Badge(rule.effect.title, color: rule.effect.color)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Lista

    @ViewBuilder
    private var reportList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Aplicativos verificados",
                subtitle: model.reports.isEmpty
                    ? "Execute a verificação para ver o resultado."
                    : "\(model.visibleReports.count) exibido(s) de \(model.reports.count)."
            )

            if !model.reports.isEmpty {
                // O filtro fica em uma linha própria, e não no cabeçalho: ele é
                // um controle, e um controle disfarçado de título é pior que
                // um título.
                HStack(spacing: Theme.Spacing.sm) {
                    Picker("Exibição", selection: filterBinding) {
                        ForEach(ProtectionModel.ReportFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()

                    Spacer(minLength: 0)
                }
            }

            if model.reports.isEmpty {
                EmptyStateView(
                    symbol: "checkmark.shield",
                    title: "Nenhuma verificação executada",
                    message: "A verificação lê a assinatura e a notarização de cada aplicativo instalado. Ela não remove nada e não altera configuração de segurança.",
                    actionLabel: "Verificar assinaturas",
                    action: { model.startAnalysis() }
                )
            } else if model.visibleReports.isEmpty {
                EmptyStateView(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: "Nenhum aplicativo neste estado",
                    message: "Nenhum aplicativo corresponde a “\(model.filter.title)” na última verificação."
                )
            } else {
                LazyVStack(spacing: Theme.Spacing.sm) {
                    ForEach(model.visibleReports) { report in
                        reportCard(report)
                    }
                }
            }
        }
    }

    private var filterBinding: Binding<ProtectionModel.ReportFilter> {
        Binding(
            get: { model.filter },
            set: { model.filter = $0 }
        )
    }

    private func reportCard(_ report: ProtectionModel.Report) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Button {
                    model.toggleExpansion(report)
                } label: {
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        Image(systemName: report.verdict.symbolName)
                            .font(Theme.Typography.bodyLarge)
                            .foregroundStyle(report.verdict.color)
                            .frame(width: 20)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(report.name)
                                .font(Theme.Typography.titleSmall)
                                .foregroundStyle(Theme.Palette.primaryText)
                            Text("\(report.version) · \(report.location.title)")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.tertiaryText)
                        }

                        Spacer(minLength: Theme.Spacing.sm)

                        Badge(report.verdict.title, color: report.verdict.color, filled: report.verdict == .suspicious)

                        Image(systemName: model.isExpanded(report) ? "chevron.up" : "chevron.down")
                            .font(Theme.Typography.iconSmall)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                PathLabel(report.url.path)

                if model.isExpanded(report) {
                    Divider().overlay(Theme.Palette.separator)
                    details(report)
                }
            }
        }
    }

    @ViewBuilder
    private func details(_ report: ProtectionModel.Report) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if report.rules.isEmpty {
                Text("Nenhuma regra disparou. Isso significa apenas que as condições avaliadas não foram encontradas — não que o aplicativo seja seguro.")
                    .font(Theme.Typography.bodySmall)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Regras que dispararam")
                        .font(Theme.Typography.captionEmphasized)
                        .foregroundStyle(Theme.Palette.secondaryText)

                    ForEach(report.rules) { rule in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: Theme.Spacing.sm) {
                                Text(rule.code)
                                    .font(Theme.Typography.path)
                                    .foregroundStyle(rule.effect.color)
                                Text(rule.title)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Palette.primaryText)
                            }
                            Text(rule.detail)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Evidência do framework Security")
                    .font(Theme.Typography.captionEmphasized)
                    .foregroundStyle(Theme.Palette.secondaryText)

                evidenceRow("Validação da assinatura", report.facts.isValid ? "válida" : "recusada (código \(report.facts.statusCode))")
                evidenceRow("Assinatura presente", report.facts.isSigned ? "sim" : "não")
                evidenceRow("Identidade", report.teamSummary)
                evidenceRow("Notarização", report.notarizationSummary)
                if let identifier = report.bundleIdentifier {
                    evidenceRow("Identificador", identifier)
                }
                if report.isAppleProvided {
                    evidenceRow("Origem", "Aplicativo fornecido pela Apple")
                }
            }
        }
    }

    private func evidenceRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Encerramento

    private var closingNotice: some View {
        LimitationNotice(
            """
            Nada nesta tela é removido, movido ou alterado. Um aplicativo classificado \
            como suspeito continua instalado, e isso é intencional: uma assinatura \
            ausente ou inválida é um indício, não uma prova, e apagar um aplicativo por \
            causa disso seria uma decisão automática e irreversível tomada com base em \
            uma suposição. Se algo aqui parecer errado, o caminho é o Gatekeeper ou a \
            desinstalação manual — sempre com você decidindo.
            """
        )
    }
}
