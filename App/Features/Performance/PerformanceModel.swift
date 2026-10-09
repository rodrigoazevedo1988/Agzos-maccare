import Darwin
import Foundation
import MacCareCore
import Observation

/// ## Estado da tela de desempenho
///
/// Reaproveita o `AppModel` compartilhado em vez de coletar métricas de novo:
/// a Visão geral, a Limpeza e esta tela leem a mesma fotografia do sistema, e
/// três coletas no mesmo instante só gastam CPU para dar o mesmo número.
///
/// ## A medição de CPU, explicada
///
/// `host_statistics(HOST_CPU_LOAD_INFO)` devolve **contadores acumulados desde
/// o boot**. Uma leitura isolada é a média desde o boot — um número real, mas
/// que não responde "quanto está sendo usado agora".
///
/// A amostragem resolve isso sem inventar API: como as frações são cumulativas,
/// a **diferença** entre duas leituras é exatamente a fração de ticks consumida
/// na janela entre elas. Duas leituras, uma subtração, e o resultado é a média
/// de uso durante os últimos segundos — que é o que o usuário quer ver.
///
/// ## O que este módulo se recusa a fazer
///
/// - Não mostra "memória usada em 63%". O macOS usa RAM de forma oportunista;
///   um número único sugere desperdício onde quase sempre há cache.
/// - Não mostra CPU por processo. Não existe API pública confiável, e o núcleo
///   devolve `cpuFraction == nil` por decisão de projeto.
/// - Não mostra temperatura. Não existe API pública, e o MacCare não lê
///   sensores privados.
@Observable
@MainActor
final class PerformanceModel {

    /// Intervalo entre leituras da amostragem.
    static let sampleInterval: TimeInterval = 2
    /// Janela mínima para aceitar uma diferença entre duas leituras. Abaixo
    /// disso a diferença entre contadores é ruído, e mostrar "0%" seria pior do
    /// que não mostrar.
    static let minimumWindow: TimeInterval = 0.5
    /// Quantidade de amostras mantidas para a faixa da CPU.
    static let historyLimit = 60

    /// Nível de proteção de um processo, no que diz respeito a encerramento.
    enum Protection {
        /// Não é um processo do MacCare — é do macOS.
        case systemCritical
        /// Pode ser encerrado pelo usuário, com confirmação.
        case ordinary
    }

    /// Resumo textual da execução de um encerramento.
    struct TerminationOutcome {
        let title: String
        let detail: String
        let succeeded: Bool
    }

    private let appModel: AppModel

    private var samplingTask: Task<Void, Never>?
    /// Geração da amostragem em curso.
    ///
    /// Existe por um motivo concreto: ao parar, o loop antigo ainda sai pelo
    /// `break` e chega ao fim sozinho. Sem comparar a geração, esse fim antigo
    /// desligaria o estado de uma amostragem nova que o usuário já começou, e o
    /// botão “Parar” sumiria da tela com a coleta ainda rodando.
    private var samplingGeneration = 0
    /// Última leitura acumulada, usada como base da próxima diferença.
    private var previousCPU: (capturedAt: Date, usage: CPUUsage)?

    private(set) var isSampling = false
    private(set) var isTimedOut = false
    /// Diferença entre as duas últimas leituras — uso **no intervalo**.
    private(set) var intervalCPU: CPUUsage?
    private(set) var intervalWindow: TimeInterval = 0
    /// Frações de uso da janela, do mais antigo ao mais recente.
    private(set) var history: [Double] = []
    private(set) var terminationOutcome: TerminationOutcome?

    init(model: AppModel) {
        self.appModel = model
    }

    // MARK: - Leitura do snapshot compartilhado

    var snapshot: SystemSnapshot? { appModel.snapshot }
    var isRefreshing: Bool { appModel.isRefreshing }

    /// Uma coleta avulsa.
    ///
    /// O primeiro toque em qualquer bloco da tela usa este caminho, para que
    /// nenhum número apareça antes de existir. Durante a amostragem, a coleta
    /// é feita pela task de amostragem — coletar aqui também registraria uma
    /// janela falsa de poucos milissegundos.
    func refresh() async {
        await appModel.refreshSnapshot()
        guard !isSampling else { return }
        guard let snapshot = appModel.snapshot, case .available(let usage) = snapshot.cpu else { return }
        record(usage: usage, capturedAt: snapshot.capturedAt)
    }

    // MARK: - Amostragem

    /// Liga a amostragem contínua.
    ///
    /// A task é cancelável e o botão "Parar" é a contraparte: a tela nunca
    /// fica coletando sozinha depois que o usuário pediu para parar.
    func startSampling() {
        guard !isSampling else { return }

        isSampling = true
        isTimedOut = false
        history = []
        intervalCPU = nil
        previousCPU = nil
        terminationOutcome = nil

        samplingGeneration += 1
        let generation = samplingGeneration

        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let model = self else { return }
                await model.takeSample()

                do {
                    try await Task.sleep(for: .seconds(PerformanceModel.sampleInterval))
                } catch {
                    break
                }
            }
            self?.endSampling(generation: generation)
        }
    }

    func stopSampling() {
        samplingGeneration += 1
        samplingTask?.cancel()
        samplingTask = nil
        isSampling = false
    }

    private func endSampling(generation: Int) {
        guard generation == samplingGeneration else { return }
        isSampling = false
        previousCPU = nil
    }

    /// Coleta e mede quanto a coleta demorou.
    ///
    /// Se a leitura passar do intervalo de amostragem, a tela avisa que os
    /// valores estão menos atualizados — em vez de entregar um número antigo
    /// com aparência de tempo real.
    private func takeSample() async {
        let started = Date()
        await appModel.refreshSnapshot()
        isTimedOut = Date().timeIntervalSince(started) > Self.sampleInterval

        guard let snapshot = appModel.snapshot, case .available(let usage) = snapshot.cpu else { return }
        record(usage: usage, capturedAt: snapshot.capturedAt)
    }

    private func record(usage: CPUUsage, capturedAt: Date) {
        defer { previousCPU = (capturedAt, usage) }

        guard let previous = previousCPU else { return }
        let window = capturedAt.timeIntervalSince(previous.capturedAt)
        guard window >= Self.minimumWindow else { return }

        // As frações são acumuladas desde o boot. A diferença entre duas
        // leituras é a fração de ticks consumida **naquela janela** — que é a
        // média de uso do período, medida de verdade.
        let user = Self.clamped(usage.user - previous.usage.user)
        let system = Self.clamped(usage.system - previous.usage.system)
        let idle = Self.clamped(usage.idle - previous.usage.idle)

        intervalCPU = CPUUsage(user: user, system: system, idle: idle)
        intervalWindow = window

        history.append(Self.clamped(user + system))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    // MARK: - Processos

    /// Nível de proteção de um processo.
    ///
    /// ## Por que uma lista, e não um palpite
    ///
    /// O macOS não expõe por API pública o dono de um processo (usuário do
    /// sistema, `_windowserver`, serviço de terceiros) nem o seu papel. A única
    /// informação que dá para ter com certeza é o nome do executável, e é por
    /// isso que a lista abaixo existe: ela cobre os componentes que o macOS
    /// precisa para funcionar e que alguém poderia encerrar por engano.
    ///
    /// O que **não** está na lista não significa "seguro": significa que o
    /// MacCare não tem como provar. Por isso a confirmação de encerramento
    /// diz isso ao usuário, em vez de apresentar a ação como algo seguro.
    func protection(of sample: ProcessSample) -> Protection {
        guard sample.id > 1, !Self.systemCriticalNames.contains(sample.name) else {
            return .systemCritical
        }
        return .ordinary
    }

    /// Componentes do macOS que o MacCare recusa a encerrar.
    private static let systemCriticalNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "SystemUIServer", "Dock",
        "loginwindow", "mds", "mds_stores", "mdworker_shared", "configd",
        "hidd", "coreaudiod", "cfprefsd", "securityd", "syspolicyd",
        "trustd", "runningboardd", "launchservicesd", "notifyd",
        "opendirectoryd", "diskarbitrationd", "powerd", "iconservicesagent",
        "CoreServicesUIAgent", "UniversalAccessAuthDaemon", "bluetoothd",
        "locationd", "fontd", "usernoted", "pboard", "secd", "lsd", "backupd",
        "nsurlsessiond", "akd", "appstoreagent", "appstoreagentd", "akidd",
        "WindowManager", "universalaccessd", "mediaanalysisd", "duetexpertd"
    ]

    /// Encerra um processo com `SIGTERM`.
    ///
    /// Decisões deliberadas:
    ///
    /// - `SIGTERM`, nunca `SIGKILL`. O processo recebe a chance de salvar o que
    ///   está em aberto e fechar limpo. Forçar é o que o macOS faz quando o
    ///   usuário usa Forçar Encerrar, e é uma decisão dele, não nossa.
    /// - Sem shell, sem `Process`. `kill` é uma chamada de sistema, e é
    ///   suficiente: enviar o sinal não exige interpretador de comandos.
    /// - Nada de escalonamento automático. Se o processo ignorar o sinal, o
    ///   app diz isso e aponta o caminho nativo.
    func terminate(_ sample: ProcessSample) {
        guard protection(of: sample) == .ordinary else {
            terminationOutcome = TerminationOutcome(
                title: "Processo protegido",
                detail: "\(sample.name) faz parte da infraestrutura do macOS. O MacCare não encerra processos de sistema.",
                succeeded: false
            )
            return
        }

        let result = kill(sample.id, SIGTERM)
        guard result == 0 else {
            let code = errno
            terminationOutcome = TerminationOutcome(
                title: "O macOS recusou o pedido",
                detail: "Não foi possível enviar o sinal de encerramento para \(sample.name) (PID \(sample.id)). Código do sistema: \(code).",
                succeeded: false
            )
            return
        }

        terminationOutcome = TerminationOutcome(
            title: "Sinal enviado para \(sample.name)",
            detail: "O processo recebeu a ordem de encerrar. Se o aplicativo não fechar, o caminho nativo é Forçar Encerrar no macOS (Command+Option+Esc).",
            succeeded: true
        )
    }

    func clearTerminationOutcome() {
        terminationOutcome = nil
    }

    // MARK: - Texto de apoio

    /// Texto do bloco de bateria, sobre autonomia.
    ///
    /// A estimativa só aparece quando o macOS a fornece. Quando não fornece,
    /// a tela diz que não foi fornecida — um "0 min" apareceria como bateria
    /// prestes a acabar sem base nenhuma.
    func autonomyText(for battery: BatteryStatus) -> String? {
        if battery.isCharging, let minutes = battery.timeToFullMinutes {
            return "Carregando — totalmente carregado em \(Self.duration(minutes))."
        }
        if !battery.isCharging, let minutes = battery.timeToEmptyMinutes {
            return "Autonomia estimada: \(Self.duration(minutes))."
        }
        return nil
    }

    private static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        if rest == 0 { return "\(hours) h" }
        return "\(hours) h \(rest) min"
    }
}
