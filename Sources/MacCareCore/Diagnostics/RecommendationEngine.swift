import Foundation

/// Severidade de uma recomendação, ordenada por urgência real.
public enum InsightSeverity: String, Codable, Sendable, Comparable, CaseIterable {
    case information
    case attention
    case action

    private var order: Int {
        switch self {
        case .action: return 2
        case .attention: return 1
        case .information: return 0
        }
    }

    public static func < (lhs: InsightSeverity, rhs: InsightSeverity) -> Bool {
        lhs.order < rhs.order
    }
}

/// Uma recomendação, sempre acompanhada do critério que a produziu.
///
/// ## Por que não existe "nota de saúde"
///
/// O PRD §6 é explícito: "não inventar uma pontuação de saúde sem critérios
/// documentados" e "não transformar indicadores informativos em alarmes
/// artificiais". Um número de 0 a 100 comprime coisas incomparáveis — disco
/// cheio e uso de CPU — em uma escala que parece objetiva e não é.
///
/// A alternativa é mais verbosa e mais honesta: dizer **o que** foi medido,
/// **qual é o limite** que disparou a recomendação, e **o que** o usuário pode
/// fazer. Um Mac com disco a 95% cheio recebe "o espaço livre está abaixo de
/// 10%" — que é verificável. Receber "saúde: 62/100" seria ficção.
public struct Insight: Identifiable, Hashable, Codable, Sendable {

    public let id: String
    public let severity: InsightSeverity
    public let title: String
    /// O que motivou a recomendação, em linguagem direta.
    public let evidence: String
    /// O limiar que disparou, para o usuário poder discordar do critério.
    public let criterion: String
    /// Rótulo da ação sugerida e o módulo que a executa.
    public let suggestedAction: String?
    public let destination: InsightDestination?

    public init(
        id: String,
        severity: InsightSeverity,
        title: String,
        evidence: String,
        criterion: String,
        suggestedAction: String? = nil,
        destination: InsightDestination? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.evidence = evidence
        self.criterion = criterion
        self.suggestedAction = suggestedAction
        self.destination = destination
    }
}

/// Para onde uma recomendação leva o usuário.
public enum InsightDestination: String, Codable, Sendable, CaseIterable {
    case storage
    case largeFiles
    case duplicates
    case smartCare
    case applications
    case performance
    case startupItems
}

/// ## Limiares
///
/// Valores únicos e documentados. Estão em um `enum` justamente para que uma
/// alteração de critério seja uma alteração visível de política, e não um
/// número mágico espalhado em um `if`.
public enum InsightThresholds {
    /// Espaço livre abaixo disso é tratado como atenção.
    public static let lowFreeSpaceFraction = 0.10
    /// Espaço livre abaixo disso é tratado como ação.
    public static let criticalFreeSpaceFraction = 0.05
    /// Carga de CPU acima disso, medida desde o boot.
    public static let highCPUFraction = 0.80
    /// Memória indisponível abaixo disso.
    public static let lowMemoryFraction = 0.15
}

/// Deriva recomendações a partir de medições reais.
///
/// Cada função só produz recomendação quando o dado **existe**. Quando a
/// medição é `unavailable`, nenhuma recomendação é gerada sobre aquele fator —
/// o que evita tanto o alarme falso quanto a falsa sensação de que "está
/// tudo bem" quando na verdade ninguém olhou.
public struct RecommendationEngine: Sendable {

    public init() {}

    public func insights(from snapshot: SystemSnapshot) -> [Insight] {
        var results: [Insight] = []

        results.append(contentsOf: storageInsights(snapshot.volume))
        results.append(contentsOf: memoryInsights(snapshot.memory))
        results.append(contentsOf: cpuInsights(snapshot.cpu))

        return results.sorted { $0.severity > $1.severity }
    }

    // MARK: - Armazenamento

    private func storageInsights(_ volume: Measurement<VolumeUsage>) -> [Insight] {
        guard case .available(let usage) = volume else { return [] }
        let free = usage.availableFraction

        if free < InsightThresholds.criticalFreeSpaceFraction {
            return [
                Insight(
                    id: "storage.critical",
                    severity: .action,
                    title: "Espaço livre está crítico",
                    evidence: "Restam \(ByteSizeFormatter.format(usage.availableCapacity)) de \(ByteSizeFormatter.format(usage.totalCapacity)).",
                    criterion: "Abaixo de \(ByteSizeFormatter.percent(InsightThresholds.criticalFreeSpaceFraction)) de espaço livre.",
                    suggestedAction: "Analisar armazenamento",
                    destination: .storage
                )
            ]
        }

        if free < InsightThresholds.lowFreeSpaceFraction {
            return [
                Insight(
                    id: "storage.low",
                    severity: .attention,
                    title: "Espaço livre está baixo",
                    evidence: "Restam \(ByteSizeFormatter.format(usage.availableCapacity)) de \(ByteSizeFormatter.format(usage.totalCapacity)).",
                    criterion: "Abaixo de \(ByteSizeFormatter.percent(InsightThresholds.lowFreeSpaceFraction)) de espaço livre.",
                    suggestedAction: "Ver arquivos grandes",
                    destination: .largeFiles
                )
            ]
        }

        return []
    }

    // MARK: - Memória

    private func memoryInsights(_ memory: Measurement<MemoryUsage>) -> [Insight] {
        guard case .available(let usage) = memory, usage.physical > 0 else { return [] }
        let availableFraction = Double(usage.available) / Double(usage.physical)

        guard availableFraction < InsightThresholds.lowMemoryFraction else { return [] }

        return [
            Insight(
                id: "memory.low",
                severity: .attention,
                title: "Memória disponível está baixa",
                evidence: "\(ByteSizeFormatter.format(usage.available)) disponíveis de \(ByteSizeFormatter.format(usage.physical))."
                    + (usage.swapUsed.map { " Swap em uso: \(ByteSizeFormatter.format($0))." } ?? ""),
                criterion: "Abaixo de \(ByteSizeFormatter.percent(InsightThresholds.lowMemoryFraction)) de memória disponível.",
                suggestedAction: "Ver processos",
                destination: .performance
            )
        ]
    }

    // MARK: - CPU

    private func cpuInsights(_ cpu: Measurement<CPUUsage>) -> [Insight] {
        guard case .available(let usage) = cpu, usage.busy > InsightThresholds.highCPUFraction else {
            return []
        }

        return [
            Insight(
                id: "cpu.high",
                severity: .information,
                title: "Processador sob carga elevada",
                evidence: "\(ByteSizeFormatter.percent(usage.busy)) em uso desde o início do sistema.",
                criterion: "Acima de \(ByteSizeFormatter.percent(InsightThresholds.highCPUFraction)) de carga média.",
                suggestedAction: "Abrir monitoramento",
                destination: .performance
            )
        ]
    }
}
