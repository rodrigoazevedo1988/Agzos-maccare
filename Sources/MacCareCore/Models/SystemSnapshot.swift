import Foundation

/// Identificação do Mac e do sistema operacional.
public struct DeviceIdentity: Hashable, Codable, Sendable {
    public var modelName: String
    public var marketingName: String?
    public var chipName: String?
    public var physicalMemory: Int64
    public var osVersion: String
    public var osBuild: String
    /// `true` quando o app roda em Apple Silicon.
    public var isAppleSilicon: Bool

    public init(
        modelName: String,
        marketingName: String? = nil,
        chipName: String? = nil,
        physicalMemory: Int64,
        osVersion: String,
        osBuild: String,
        isAppleSilicon: Bool
    ) {
        self.modelName = modelName
        self.marketingName = marketingName
        self.chipName = chipName
        self.physicalMemory = physicalMemory
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.isAppleSilicon = isAppleSilicon
    }

    public var displayName: String { marketingName ?? modelName }

    public var processorSummary: String {
        if let chipName, isAppleSilicon { return chipName }
        if let chipName { return chipName }
        return modelName
    }
}

/// Uso de processador no instante da medição.
public struct CPUUsage: Hashable, Codable, Sendable {
    /// Fração 0...1 ocupada pelo usuário.
    public let user: Double
    /// Fração 0...1 ocupada pelo sistema.
    public let system: Double
    /// Fração 0...1 ociosa.
    public let idle: Double

    public init(user: Double, system: Double, idle: Double) {
        self.user = user
        self.system = system
        self.idle = idle
    }

    /// Carga total (usuário + sistema).
    public var busy: Double { min(max(user + system, 0), 1) }
}

/// Componentes de memória, apresentados separadamente.
///
/// O PRD §15 é explícito: "não simplificar a memória do macOS em uma única
/// porcentagem enganosa". O macOS usa RAM de forma oportunista — memória
/// "usada" não é memória perdida. Expor os componentes permite ao usuário
/// entender o que está acontecendo.
public struct MemoryUsage: Hashable, Codable, Sendable {
    public let physical: Int64
    public let wired: Int64
    public let active: Int64
    public let compressed: Int64
    public let free: Int64
    public let available: Int64
    public let swapUsed: Int64?

    public init(
        physical: Int64,
        wired: Int64,
        active: Int64,
        compressed: Int64,
        free: Int64,
        available: Int64,
        swapUsed: Int64?
    ) {
        self.physical = physical
        self.wired = wired
        self.active = active
        self.compressed = compressed
        self.free = free
        self.available = available
        self.swapUsed = swapUsed
    }

    /// Total em uso, definido como `física - disponível`.
    public var used: Int64 { max(0, physical - available) }
    public var usedFraction: Double { physical > 0 ? Double(used) / Double(physical) : 0 }
}

/// Estado da bateria, quando o dispositivo tem uma.
public struct BatteryStatus: Hashable, Codable, Sendable {
    public let chargePercent: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    /// Condição informada por API pública, quando disponível.
    public let condition: String?
    /// Tempo restante estimado. Só preenchido quando o sistema é confiável.
    public let timeToEmptyMinutes: Int?
    public let timeToFullMinutes: Int?

    public init(
        chargePercent: Int,
        isCharging: Bool,
        isPluggedIn: Bool,
        condition: String? = nil,
        timeToEmptyMinutes: Int? = nil,
        timeToFullMinutes: Int? = nil
    ) {
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.condition = condition
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullMinutes = timeToFullMinutes
    }
}

/// Ocupação do volume do sistema.
public struct VolumeUsage: Hashable, Codable, Sendable {
    public let volumeName: String
    public let mountPoint: URL
    public let totalCapacity: Int64
    public let availableCapacity: Int64

    public init(volumeName: String, mountPoint: URL, totalCapacity: Int64, availableCapacity: Int64) {
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }

    public var used: Int64 { max(0, totalCapacity - availableCapacity) }
    public var usedFraction: Double { totalCapacity > 0 ? Double(used) / Double(totalCapacity) : 0 }
    public var availableFraction: Double {
        totalCapacity > 0 ? Double(min(max(availableCapacity, 0), totalCapacity)) / Double(totalCapacity) : 0
    }
}

/// Uma execução do sistema observada pelo monitor.
public struct ProcessSample: Hashable, Codable, Identifiable, Sendable {
    public let id: Int32
    public let name: String
    public let executablePath: String?
    public let residentMemory: Int64
    /// Uso de CPU por processo. `nil` quando a fonte não está disponível —
    /// ver `docs/ARCHITECTURE.md`, seção "Limites das APIs de processo".
    public let cpuFraction: Double?

    public init(id: Int32, name: String, executablePath: String?, residentMemory: Int64, cpuFraction: Double? = nil) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.residentMemory = residentMemory
        self.cpuFraction = cpuFraction
    }
}

/// Fotografia completa do estado do Mac em um instante.
public struct SystemSnapshot: Hashable, Codable, Sendable {
    public let capturedAt: Date
    public let device: DeviceIdentity
    public let cpu: Measurement<CPUUsage>
    public let memory: Measurement<MemoryUsage>
    public let volume: Measurement<VolumeUsage>
    public let battery: Measurement<BatteryStatus>
    public let topProcesses: [ProcessSample]
    public let totalProcessCount: Int

    public init(
        capturedAt: Date,
        device: DeviceIdentity,
        cpu: Measurement<CPUUsage>,
        memory: Measurement<MemoryUsage>,
        volume: Measurement<VolumeUsage>,
        battery: Measurement<BatteryStatus>,
        topProcesses: [ProcessSample],
        totalProcessCount: Int
    ) {
        self.capturedAt = capturedAt
        self.device = device
        self.cpu = cpu
        self.memory = memory
        self.volume = volume
        self.battery = battery
        self.topProcesses = topProcesses
        self.totalProcessCount = totalProcessCount
    }
}
