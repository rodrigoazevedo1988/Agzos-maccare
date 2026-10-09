import MacCareCore
import SwiftUI

/// ## Desempenho
///
/// CPU, memória, processos, bateria e temperatura — com a mesma regra em todas
/// as seções: **o que o macOS não mede de forma confiável aparece como
/// indisponível, com o motivo, e nunca como zero**.
///
/// A tela é deliberadamente fragmentada em componentes em vez de um número
/// único. No macOS, memória ocupada quase sempre é cache recuperável, e um
/// "63% de memória em uso" sugere desperdício onde quase não há. Mesma lógica
/// vale para CPU: a leitura base é a média desde o boot, e por isso ela é
/// rotulada assim — quem quer o instante, liga a amostragem.
struct PerformanceView: View {

    /// Injeção vinda da navegação. O estado observável vive em
    /// `PerformanceModel`, que guarda este mesmo `AppModel` para que as
    /// coletas desta tela alimentem a Visão geral em vez de duplicá-las.
    let model: AppModel

    @State private var performance: PerformanceModel
    @State private var processToTerminate: ProcessSample?
    @State private var showsTerminationConfirmation = false
    /// Coluna pela qual a tabela está ordenada. Vive como propriedade da view
    /// porque um `@State` criado dentro de um método seria recriado a cada
    /// atualização do corpo e a ordenação voltaria ao padrão sem aviso.
    @State private var processSortOrder = [KeyPathComparator(\ProcessSample.residentMemory, order: .reverse)]

    init(model: AppModel) {
        self.model = model
        _performance = State(initialValue: PerformanceModel(model: model))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let snapshot = performance.snapshot {
                    header(snapshot)
                    cpuSection(snapshot)
                    memorySection(snapshot)
                    batterySection(snapshot)
                    temperatureSection
                    processesSection(snapshot)
                } else {
                    initialState
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.Palette.canvas)
        .onDisappear {
            // A amostragem é uma decisão do usuário, e ela não sobrevive ao fim
            // da tela: sair do módulo para de coletar.
            performance.stopSampling()
        }
        .confirmationDialog(
            "Encerrar \(processToTerminate?.name ?? "este processo")?",
            isPresented: $showsTerminationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Encerrar processo", role: .destructive) {
                if let sample = processToTerminate {
                    performance.terminate(sample)
                }
                processToTerminate = nil
            }
            Button("Cancelar", role: .cancel) {
                processToTerminate = nil
            }
        } message: {
            Text(terminationMessage)
        }
    }

    // MARK: - Cabeçalho

    private func header(_ snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(snapshot.device.displayName)
                        .font(Theme.Typography.displayMedium)
                        .foregroundStyle(Theme.Palette.primaryText)

                    Text("Leitura de \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }

                Spacer(minLength: Theme.Spacing.md)

                HStack(spacing: Theme.Spacing.sm) {
                    if performance.isSampling {
                        Button {
                            performance.stopSampling()
                        } label: {
                            Label("Parar amostragem", systemImage: "stop.circle")
                                .font(Theme.Typography.body)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    } else {
                        PrimaryActionButton(
                            "Amostrar uso de CPU",
                            symbol: "waveform.path.ecg",
                            isBusy: performance.isRefreshing,
                            action: { performance.startSampling() }
                        )
                    }

                    Button {
                        Task { await performance.refresh() }
                    } label: {
                        Label("Atualizar", systemImage: "arrow.clockwise")
                            .font(Theme.Typography.body)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(performance.isRefreshing)
                }
            }

            if let outcome = performance.terminationOutcome {
                ProcessOutcomeNotice(outcome: outcome) {
                    performance.clearTerminationOutcome()
                }
            }
        }
    }

    private var initialState: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if performance.isRefreshing {
                    HStack(spacing: Theme.Spacing.md) {
                        ProgressView().controlSize(.small)
                        Text("Coletando o estado do sistema…")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                } else {
                    EmptyStateView(
                        symbol: "chart.xyaxis.line",
                        title: "Nenhuma leitura ainda",
                        message: "O MacCare ainda não coletou métricas deste Mac. A coleta lê o estado atual do sistema — não varre o disco e não altera nada.",
                        actionLabel: "Coletar agora",
                        action: { Task { await performance.refresh() } }
                    )
                }
            }
        }
    }

    // MARK: - CPU

    private func cpuSection(_ snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Processador",
                subtitle: "A leitura base é a média desde o boot. A amostragem mede o uso no intervalo."
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Theme.Metrics.tileMinWidth), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                StatTile(
                    "Média desde o boot",
                    symbol: "clock.arrow.circlepath",
                    tint: Theme.Palette.secondaryText,
                    value: snapshot.cpu.map { ByteSizeFormatter.percent($0.busy) },
                    caption: snapshot.cpu.map {
                        "Usuário \(ByteSizeFormatter.percent($0.user)) · Sistema \(ByteSizeFormatter.percent($0.system)) · Ocioso \(ByteSizeFormatter.percent($0.idle))"
                    }
                )

                if let usage = performance.intervalCPU {
                    StatTile(
                        // Parada a amostragem, o valor continua no lugar — mas
                        // com outro rótulo. Um número de janela congelado
                        // apresentado como "agora" seria uma mentira pequena e
                        // difícil de perceber.
                        performance.isSampling ? "Uso no intervalo" : "Último intervalo medido",
                        symbol: "waveform.path.ecg",
                        tint: performance.isSampling ? Theme.Palette.accent : Theme.Palette.secondaryText,
                        value: .available(ByteSizeFormatter.percent(usage.busy)),
                        caption: "Média de \(Int(performance.intervalWindow)) s entre leituras · usuário \(ByteSizeFormatter.percent(usage.user)) · sistema \(ByteSizeFormatter.percent(usage.system))"
                            + (performance.isSampling ? "" : " · amostragem parada")
                    )
                }
            }

            if performance.intervalCPU == nil {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Uso no instante")
                            .font(Theme.Typography.titleSmall)
                            .foregroundStyle(Theme.Palette.primaryText)

                        Text("O macOS só publica o contador acumulado de CPU desde o último reinício. Para obter o uso atual, o MacCare compara duas leituras: a diferença entre elas é a fração de tempo de processador realmente ocupada na janela entre as leituras. Isso é medido, não estimado.")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        if !performance.history.isEmpty {
                            CPUSampleStrip(samples: performance.history)
                            Text("Amostras reais dos últimos \(Int(Double(performance.history.count) * PerformanceModel.sampleInterval)) s, uma a cada \(Int(PerformanceModel.sampleInterval)) s de amostragem. Enquanto a amostragem está parada, esta faixa não cresce.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Use “Amostrar uso de CPU” no topo para medir o uso por intervalos de \(Int(PerformanceModel.sampleInterval)) segundos.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack {
                            Text("Histórico da amostragem")
                                .font(Theme.Typography.titleSmall)
                                .foregroundStyle(Theme.Palette.primaryText)
                            Spacer()
                            if !performance.isSampling {
                                Badge("Parada", color: Theme.Palette.secondaryText)
                            }
                            Text("\(performance.history.count) amostras")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.tertiaryText)
                        }

                        CPUSampleStrip(samples: performance.history)

                        Text("Cada barra é a fração de processador ocupada na janela de \(Int(PerformanceModel.sampleInterval)) s que termina naquele ponto. Leituras reais, acumuladas desde que a amostragem começou. \(performance.isSampling ? "" : "A amostragem está parada, então a faixa não cresce até você iniciá-la de novo.")")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if performance.isTimedOut {
                LimitationNotice(
                    "A última coleta demorou mais que o intervalo de \(Int(PerformanceModel.sampleInterval)) segundos. Os valores continuam sendo reais, mas chegam com atraso — reduza a carga do Mac para leituras mais regulares.",
                    severity: .warning
                )
            }
        }
    }

    // MARK: - Memória

    /// ## Por que não existe "63% de memória usada"
    ///
    /// O PRD §15 proíbe a simplificação, e o motivo é técnico, não estético:
    /// o macOS comprime e recicla memória de forma oportunista. O que o
    /// `Monitor de Atividade` mostra como "usado" inclui cache que será
    /// descartado em segundos. Um número único e colorido de vermelho ensina o
    /// usuário a comprar RAM que ele não precisa.
    ///
    /// A alternativa honesta é expor os componentes: ativa, ligada, comprimida,
    /// livre, disponível e swap — e deixar o usuário interpretar.
    private func memorySection(_ snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Memória",
                subtitle: "Componentes separados, como o macOS realmente os usa."
            )

            switch snapshot.memory {
            case .available(let usage):
                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(ByteSizeFormatter.format(usage.physical))
                                    .font(Theme.Typography.metric)
                                    .foregroundStyle(Theme.Palette.primaryText)
                                Text("memória física total")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.tertiaryText)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                                Text(ByteSizeFormatter.format(usage.available))
                                    .font(Theme.Typography.metric)
                                    .foregroundStyle(Theme.Palette.primaryText)
                                Text("disponível agora")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.tertiaryText)
                            }
                        }

                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            MemoryRow(
                                title: "Ativa",
                                detail: "Memória em uso por aplicativos e pelo sistema em execução.",
                                bytes: usage.active,
                                total: usage.physical
                            )
                            MemoryRow(
                                title: "Ligada ao sistema",
                                detail: "Páginas que o kernel não pode trocar para disco.",
                                bytes: usage.wired,
                                total: usage.physical
                            )
                            MemoryRow(
                                title: "Comprimida",
                                detail: "Memória compactada pelo macOS para caber mais dados na mesma RAM.",
                                bytes: usage.compressed,
                                total: usage.physical
                            )
                            MemoryRow(
                                title: "Livre",
                                detail: "Páginas nunca usadas, disponíveis imediatamente.",
                                bytes: usage.free,
                                total: usage.physical
                            )
                            MemoryRow(
                                title: "Disponível",
                                detail: "Memória que o sistema entregaria a um novo aplicativo sem swap.",
                                bytes: usage.available,
                                total: usage.physical
                            )

                            if let swap = usage.swapUsed {
                                MemoryRow(
                                    title: "Swap em disco",
                                    detail: "Memória virtualizada em arquivo. Só cresce quando a RAM disponível acaba.",
                                    bytes: swap,
                                    total: usage.physical
                                )
                            } else {
                                UnavailableRow("Swap em disco", "O macOS não informou o uso de memória virtualizada nesta leitura.")
                            }
                        }

                        LimitationNotice(
                            "O MacCare não mostra um percentual único de memória usada. No macOS, memória ocupada é quase sempre memória reciclável: o sistema comprime e libera sozinho. Uma barra em vermelho sugeriria um problema que, na maioria das vezes, não existe.",
                            severity: .information
                        )
                    }
                }
            case .unavailable(let reason):
                Card {
                    EmptyStateView(
                        symbol: "memorychip",
                        title: "Memória indisponível",
                        message: reason.explanation,
                        actionLabel: "Tentar de novo",
                        action: { Task { await performance.refresh() } }
                    )
                }
            }
        }
    }

    // MARK: - Bateria

    private func batterySection(_ snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader("Bateria")

            switch snapshot.battery {
            case .available(let battery):
                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                            Text("\(battery.chargePercent)%")
                                .font(Theme.Typography.metric)
                                .foregroundStyle(Theme.Palette.primaryText)

                            Text(statusText(battery))
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.secondaryText)

                            Spacer(minLength: 0)
                        }

                        if let autonomy = performance.autonomyText(for: battery) {
                            HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                                Image(systemName: "clock")
                                    .font(Theme.Typography.micro)
                                    .foregroundStyle(Theme.Palette.tertiaryText)
                                    .padding(.top, 2)
                                Text(autonomy)
                                    .font(Theme.Typography.bodySmall)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                        } else {
                            UnavailableRow(
                                "Autonomia",
                                "O macOS não forneceu uma estimativa confiável de tempo restante nesta leitura."
                            )
                        }

                        if let condition = battery.condition, !condition.isEmpty {
                            HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                                Image(systemName: "info.circle")
                                    .font(Theme.Typography.micro)
                                    .foregroundStyle(Theme.Palette.tertiaryText)
                                    .padding(.top, 2)
                                Text("Condição informada pelo sistema: \(condition)")
                                    .font(Theme.Typography.bodySmall)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                        }
                    }
                }
            case .unavailable(let reason):
                // Em um Mac de mesa a ausência de bateria é o resultado
                // correto, não uma falha. O texto do motivo já diz "Este Mac não
                // possui o sensor correspondente" — e a tela acrescenta o
                // contexto para que ninguém procure uma bateria que não existe.
                Card {
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        Image(systemName: "powerplug")
                            .font(Theme.Typography.titleMedium)
                            .foregroundStyle(Theme.Palette.unavailable)

                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(batteryAbsenceTitle(reason))
                                .font(Theme.Typography.titleSmall)
                                .foregroundStyle(Theme.Palette.primaryText)

                            Text(reason.explanation)
                                .font(Theme.Typography.bodySmall)
                                .foregroundStyle(Theme.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func statusText(_ battery: BatteryStatus) -> String {
        if battery.isCharging { return "Carregando" }
        if battery.isPluggedIn { return "Ligado à energia" }
        return "Usando a bateria"
    }

    private func batteryAbsenceTitle(_ reason: UnavailableReason) -> String {
        switch reason {
        case .hardwareNotPresent:
            return "Este Mac não tem bateria"
        default:
            return "Bateria indisponível"
        }
    }

    // MARK: - Temperatura

    /// ## Um bloco sem gráfico, de propósito
    ///
    /// Existem bibliotecas que leem sensores por frames privados de IOKit, e
    /// de IOKit, e elas funcionam. É exatamente por isso que não são usadas:
    /// o resultado seria um número real vindo de uma superfície não suportada,
    /// que pode deixar de funcionar sem aviso e que impede o app de ser
    /// assinado para distribuição confiável.
    ///
    /// A alternativa honesta é a frase: não existe API pública, então não há
    /// número. Um gráfico aqui seria o tipo de preenchimento visual que o
    /// projeto existe para evitar.
    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader("Temperatura")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Theme.Metrics.tileMinWidth), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                StatTile(
                    "Temperatura da CPU",
                    symbol: "thermometer.medium",
                    tint: Theme.Palette.unavailable,
                    value: .unavailable(.noPublicAPI)
                )
            }

            LimitationNotice(
                "O macOS não oferece API pública para ler a temperatura dos sensores. Existem bibliotecas que usam estruturas privadas de IOKit, e o MacCare não as usa: um número vindo de superfície não suportada pode parar de funcionar sem aviso. Para acompanhar a temperatura, use o Monitor de Atividade ou o app Fabric do seu fabricante.",
                severity: .information
            )
        }
    }

    // MARK: - Processos

    private func processesSection(_ snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Processos",
                subtitle: "Amostra dos \(snapshot.topProcesses.count) processos com maior memória, entre \(snapshot.totalProcessCount) em execução."
            )

            Card(padding: Theme.Spacing.xs) {
                Table(snapshot.topProcesses, sortOrder: $processSortOrder) {
                    TableColumn("Nome", value: \.name) { sample in
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(sample.name)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.primaryText)

                            if performance.protection(of: sample) == .systemCritical {
                                Badge("Sistema", color: Theme.Palette.secondaryText)
                            }
                        }
                    }
                    .width(min: 180, ideal: 260)

                    TableColumn("PID", value: \.id) { sample in
                        Text("\(sample.id)")
                            .font(Theme.Typography.path)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .monospacedDigit()
                    }
                    .width(min: 50, ideal: 60)

                    TableColumn("Memória", value: \.residentMemory) { sample in
                        Text(ByteSizeFormatter.format(sample.residentMemory))
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText)
                            .monospacedDigit()
                    }
                    .width(min: 90, ideal: 110)

                    // A coluna existe e diz "Indisponível" porque a ausência é
                    // informação: o macOS não publica CPU por processo em API
                    // pública, e esconder a coluna faria o usuário achar que
                    // faltou um dado. A explicação está logo abaixo.
                    TableColumn("CPU") { sample in
                        HStack(spacing: Theme.Spacing.xxs) {
                            Image(systemName: "minus")
                                .font(Theme.Typography.iconSmall)
                            Text(sample.cpuFraction.map { ByteSizeFormatter.percent($0) } ?? "Indisponível")
                                .font(Theme.Typography.caption)
                        }
                        .foregroundStyle(Theme.Palette.unavailable)
                    }
                    .width(min: 110, ideal: 130)

                    TableColumn("Ação") { sample in
                        actionCell(sample)
                    }
                    .width(min: 110, ideal: 130)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: 320)
            }

            LimitationNotice(
                "CPU por processo é “Indisponível” em todas as linhas. O macOS não expõe esse dado em API pública documentada — a função que o forneceria pertence à superfície não documentada e responde de forma inconsistente. O MacCare prefere dizer que não sabe a exibir um número que às vezes funciona.",
                severity: .information
            )

            LimitationNotice(
                "Encerrar um processo é paliativo, nunca solução. Um Mac lento costuma ter causa em armazenamento, indexadores, atualizações pendentes ou thermal throttling — encerrar o processo apenas devolve a folga por alguns minutos, e o que não foi salvo pode se perder. Feche o aplicativo que está consumindo recursos, quando possível.",
                severity: .warning
            )
        }
    }

    @ViewBuilder
    private func actionCell(_ sample: ProcessSample) -> some View {
        switch performance.protection(of: sample) {
        case .systemCritical:
            Text("Protegido")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
                .help("Este processo faz parte da infraestrutura do macOS. O MacCare não o encerra.")
        case .ordinary:
            Button("Encerrar") {
                processToTerminate = sample
                showsTerminationConfirmation = true
            }
            .buttonStyle(.link)
            .font(Theme.Typography.bodySmall)
            .help("Envia um pedido de encerramento. O que não for salvo pode se perder.")
        }
    }

    private var terminationMessage: String {
        guard let sample = processToTerminate else { return "" }
        return """
        \(sample.name) (PID \(sample.id), \(ByteSizeFormatter.format(sample.residentMemory)) de memória) será \
        avisado para encerrar. O que estiver aberto e não salvo pode se perder, e o aplicativo pode pedir \
        para reabrir em menos de um minuto.

        Encerrar processo é uma medida paliativa: se o Mac está lento, a causa provavelmente está em outro lugar.
        """
    }
}

// MARK: - Faixa de amostras

/// Barras das amostras reais de CPU.
///
/// Desenhadas com formas, sem biblioteca de gráficos: são valores medidos,
/// e a única decisão de design aqui é a escala.
private struct CPUSampleStrip: View {

    let samples: [Double]

    private let barHeight: CGFloat = 56

    private var tint: Color {
        guard let last = samples.last else { return Theme.Palette.accent }
        if last > 0.75 { return Theme.Palette.danger }
        if last > 0.4 { return Theme.Palette.warning }
        return Theme.Palette.accent
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(tint.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, CGFloat(min(max(sample, 0), 1)) * barHeight))
            }
        }
        .frame(height: barHeight, alignment: .bottom)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.Palette.canvas)
        )
        .accessibilityLabel("Histórico de uso do processador")
    }
}

// MARK: - Componente de memória

private struct MemoryRow: View {

    let title: String
    let detail: String
    let bytes: Int64
    let total: Int64

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(bytes) / Double(total), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Theme.Typography.bodyLarge)
                    .foregroundStyle(Theme.Palette.primaryText)

                Spacer(minLength: Theme.Spacing.md)

                Text(ByteSizeFormatter.format(bytes))
                    .font(Theme.Typography.metricSmall)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .monospacedDigit()

                Text(ByteSizeFormatter.percent(fraction, fractionDigits: 1))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.separator)
                    Capsule()
                        .fill(Theme.Palette.accent.opacity(0.75))
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(height: 6)

            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Blocos auxiliares

/// Linha "indisponível" com o motivo, usada onde um componente não existe.
private struct UnavailableRow: View {
    let title: String
    let reason: String

    init(_ title: String, _ reason: String) {
        self.title = title
        self.reason = reason
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "minus")
                .font(Theme.Typography.iconSmall)
                .foregroundStyle(Theme.Palette.unavailable)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(Theme.Typography.bodyLarge)
                    .foregroundStyle(Theme.Palette.secondaryText)
                Text(reason)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Resultado de uma ação sobre um processo, com o mesmo cuidado de tom das
/// demais mensagens: o que aconteceu, e o que fazer se não for o esperado.
private struct ProcessOutcomeNotice: View {

    let outcome: PerformanceModel.TerminationOutcome
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: outcome.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                .font(Theme.Typography.bodySmall)
                .foregroundStyle(outcome.succeeded ? Theme.Palette.success : Theme.Palette.warning)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(outcome.title)
                    .font(Theme.Typography.titleSmall)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(outcome.detail)
                    .font(Theme.Typography.bodySmall)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Spacing.sm)

            Button("OK", action: onDismiss)
                .buttonStyle(.link)
                .font(Theme.Typography.body)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill((outcome.succeeded ? Theme.Palette.success : Theme.Palette.warning).opacity(0.08))
        )
    }
}
