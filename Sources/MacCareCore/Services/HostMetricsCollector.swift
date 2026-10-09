import Darwin
import Foundation
import IOKit.ps

/// ## Sobre este arquivo
///
/// Todo acesso a métricas do host passa por aqui, e cada leitura é isolada em
/// uma função que devolve `Measurement<...>` em vez de um valor cru. O motivo
/// é o requisito do PRD §15 e §28: quando o macOS não expõe um dado, o app
/// exibe **"indisponível"** — nunca zero, nunca estimativa silenciosa.
///
/// ## O que este arquivo deliberadamente NÃO faz
///
/// - Não lê sensores de temperatura. Não existe API pública no macOS; as
///   bibliotecas que fazem isso usam frames privados de IOKit. O app mostra
///   "Indisponível" permanentemente em vez de inventar um número.
/// - Não estima "pressão de memória". Não existe API pública.
/// - Não inventa CPU por processo. Ver `listProcesses()`.
///
/// ## APIs usadas — todas públicas
///
/// | Dado | API |
/// |------|-----|
/// | Modelo / chip | `sysctlbyname` |
/// | CPU total | `host_statistics(HOST_CPU_LOAD_INFO)` |
/// | Memória | `host_statistics64(HOST_VM_INFO64)` + `os_proc_available_memory` |
/// | Bateria | `IOPSCopyPowerSourcesInfo` |
/// | Processos | `sysctl(KERN_PROC_ALL)` |
public struct HostMetricsCollector: Sendable {

    public init() {}

    // MARK: - Identidade do dispositivo

    public func deviceIdentity() -> DeviceIdentity {
        let version = ProcessInfo.processInfo.operatingSystemVersion

        return DeviceIdentity(
            modelName: sysctlString("hw.model") ?? "Modelo desconhecido",
            // O nome comercial ("MacBook Pro 14") não é exposto por nenhuma API
            // pública do macOS. Montar um mapeamento de modelo para nome seria
            // exatamente o tipo de resultado plausível-e-errado que o projeto
            // existe para evitar.
            marketingName: nil,
            chipName: sysctlString("machdep.cpu.brand_string"),
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            osBuild: sysctlString("kern.osversion") ?? "—",
            isAppleSilicon: isAppleSilicon
        )
    }

    private var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return sysctlInt("hw.optional.arm64") == 1
        #endif
    }

    // MARK: - CPU

    /// Carga do processador desde o boot.
    ///
    /// `HOST_CPU_LOAD_INFO` devolve contadores acumulados de ticks. Uma única
    /// leitura dá a média desde o boot — um número real e verificável, mas
    /// que **não** é "uso atual". A interface rotula como tal, e o monitor
    /// (§15) faz amostragem sucessiva quando precisa de velocidade.
    public func cpuUsage() -> Measurement<CPUUsage> {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            host_statistics(
                mach_host_self(),
                HOST_CPU_LOAD_INFO,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: host_info_t.self),
                &count
            )
        }

        guard result == KERN_SUCCESS else { return .unavailable(.ioFailure) }

        let ticks = info.cpu_ticks
        let user = Double(ticks.0)
        let system = Double(ticks.1)
        let idle = Double(ticks.2)
        let nice = Double(ticks.3)
        let total = user + system + idle + nice

        guard total > 0 else { return .unavailable(.ioFailure) }

        return .available(
            CPUUsage(user: user / total, system: system / total, idle: idle / total)
        )
    }

    // MARK: - Memória

    /// Componentes de memória, separados.
    ///
    /// O macOS trata RAM como cache: "usada" não é "perdida". Por isso o
    /// resultado não colapsa em um número único — o PRD §15 proíbe
    /// explicitamente essa simplificação.
    public func memoryUsage() -> Measurement<MemoryUsage> {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            host_statistics64(
                mach_host_self(),
                HOST_VM_INFO64,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: host_info_t.self),
                &count
            )
        }

        guard result == KERN_SUCCESS else { return .unavailable(.ioFailure) }

        let pageSize = Int64(currentPageSize())

        return .available(
            MemoryUsage(
                physical: ProcessInfo.processInfo.physicalMemory,
                wired: Int64(stats.wire_count) * pageSize,
                active: Int64(stats.active_count) * pageSize,
                compressed: Int64(stats.compressor_page_count) * pageSize,
                free: Int64(stats.free_count) * pageSize,
                // `os_proc_available_memory` (macOS 13+) considera memória
                // comprimida e inativa de forma mais fiel do que `free_count`.
                available: Int64(os_proc_available_memory()),
                swapUsed: swapUsage()?.used
            )
        )
    }

    private func swapUsage() -> (used: Int64, total: Int64)? {
        var usage = xsw_usage()
        var length = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &length, nil, 0) == 0 else { return nil }
        return (Int64(usage.used), Int64(usage.total))
    }

    private func currentPageSize() -> Int {
        var pageSize: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.pagesize", &pageSize, &length, nil, 0) == 0, pageSize > 0 else {
            return 4096
        }
        return Int(pageSize)
    }

    // MARK: - Volume

    public func volumeUsage() -> Measurement<VolumeUsage> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeNameKey
        ]) else {
            return .unavailable(.permissionNotGranted)
        }

        let total = values.volumeTotalCapacity.map { Int64($0) } ?? 0
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        guard total > 0 else { return .unavailable(.ioFailure) }

        return .available(
            VolumeUsage(
                volumeName: values.volumeName ?? "Disco do sistema",
                mountPoint: URL(fileURLWithPath: "/", isDirectory: true),
                totalCapacity: total,
                availableCapacity: available
            )
        )
    }

    // MARK: - Bateria

    /// Estado da bateria, quando o dispositivo tiver uma.
    ///
    /// Em Macs de mesa, `IOPSCopyPowerSourcesList` devolve uma lista **vazia**.
    /// Isso é o resultado correto — e não uma falha: o app diz "indisponível"
    /// porque o hardware não tem bateria.
    public func batteryStatus() -> Measurement<BatteryStatus> {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unavailable(.ioFailure)
        }
        guard
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
            let first = sources.first,
            let description = IOPSGetPowerSourceDescription(blob, first)?
                .takeUnretainedValue() as? [String: Any]
        else {
            return .unavailable(.hardwareNotPresent)
        }

        guard
            let current = description[kIOPSCurrentCapacityKey as String] as? Int,
            let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
            maximum > 0
        else {
            return .unavailable(.hardwareNotPresent)
        }

        return .available(
            BatteryStatus(
                chargePercent: min(100, max(0, (current * 100) / maximum)),
                isCharging: (description[kIOPSIsChargingKey as String] as? Bool) ?? false,
                isPluggedIn: (description[kIOPSPowerSourceStateKey as String] as? String)
                    == kIOPSACPowerValue,
                // A Apple não expõe "saúde da bateria" por API pública.
                // Deixar `nil` é correto; um número aqui seria invenção.
                condition: nil,
                timeToEmptyMinutes: positiveMinutes(description[kIOPSTimeToEmptyKey as String]),
                timeToFullMinutes: positiveMinutes(description[kIOPSTimeToFullChargeKey as String])
            )
        )
    }

    /// Converte minutos estimados, descartando o sentinela do sistema.
    ///
    /// O IOKit usa `-1` para "estimativa indisponível". Tratar isso como
    /// "descarrega em 1 minuto" seria um erro concreto e visível.
    private func positiveMinutes(_ value: Any?) -> Int? {
        guard let raw = value as? Int, raw > 0 else { return nil }
        return raw
    }

    // MARK: - Processos

    /// Lista processos ordenada por memória residente.
    ///
    /// ## Por que `cpuFraction` é sempre `nil`
    ///
    /// O macOS não expõe CPU por processo em API pública documentada.
    /// `proc_pid_rusage` existe em `<libproc.h>`, mas pertence à superfície
    /// não documentada e responde de forma inconsistente sob App Sandbox.
    /// Usá-la produziria um número que às vezes funciona e às vezes não, sem
    /// que o usuário pudesse saber qual dos dois está olhando. O app prefere
    /// dizer "indisponível". O campo existe na API para quando uma fonte
    /// confiável surgir.
    public func listProcesses(limit: Int = 50) -> (samples: [ProcessSample], total: Int) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length: UInt = 0

        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 0 else { return ([], 0) }

        let stride = MemoryLayout<kinfo_proc>.stride
        let count = Int(length) / stride
        guard count > 0 else { return ([], 0) }

        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var bufferLength: UInt = length

        let result = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &bufferLength, nil, 0)
        }
        guard result == 0 else { return ([], 0) }

        let usable = min(Int(bufferLength) / stride, count)
        guard usable > 0 else { return ([], 0) }

        var samples: [ProcessSample] = []
        samples.reserveCapacity(usable)

        for index in 0..<usable {
            var entry = buffer[index]
            let pid = entry.kp_proc.p_pid
            guard pid > 0 else { continue }

            // `e_xrssize` é em bytes no macOS (em páginas no iOS, que não se aplica).
            let resident = Int64(entry.kp_eproc.e_xrssize)
            guard resident > 0 else { continue }

            samples.append(
                ProcessSample(
                    id: pid,
                    name: Self.commandName(&entry),
                    executablePath: nil,
                    residentMemory: resident,
                    cpuFraction: nil
                )
            )
        }

        let sorted = samples.sorted { $0.residentMemory > $1.residentMemory }
        return (Array(sorted.prefix(limit)), samples.count)
    }

    /// Converte `p_comm` (tupla C de tamanho fixo) em `String`.
    private static func commandName(_ process: inout kinfo_proc) -> String {
        withUnsafePointer(to: &process.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { cString in
                String(cString: cString)
            }
        }
    }

    // MARK: - sysctl

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
