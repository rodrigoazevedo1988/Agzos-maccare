import Foundation

/// Motivo pelo qual um dado não pôde ser obtido.
///
/// O PRD (§15, §6 e §28) exige que a falta de dados vire um *estado
/// indisponível*, nunca um valor inventado. Este enum é o vocabulário único
/// desse estado: a interface renderiza o motivo, não um zero.
public enum UnavailableReason: String, Codable, Sendable, CaseIterable {
    /// O hardware não expõe o sensor (ex.: temperatura em um Mac mini).
    case hardwareNotPresent
    /// A API existe mas não está disponível na versão do macOS em execução.
    case osVersionNotSupported
    /// O usuário ainda não concedeu a permissão, ou a concedida não cobre este volume.
    case permissionNotGranted
    /// A API funciona fora do sandbox e o app está com App Sandbox habilitado.
    case restrictedBySandbox
    /// Não existe API pública e confiável no macOS para este dado.
    /// Este é o caso da temperatura do Mac — ver README, "Limitações reais".
    case noPublicAPI
    /// A medição foi cancelada pelo usuário antes de terminar.
    case cancelled
    /// A coleta falhou por erro de I/O.
    case ioFailure

    /// Explicação em português brasileiro exibida ao usuário.
    public var explanation: String {
        switch self {
        case .hardwareNotPresent:
            return "Este Mac não possui o sensor correspondente."
        case .osVersionNotSupported:
            return "O macOS em execução não expõe esse dado."
        case .permissionNotGranted:
            return "Permissão não concedida. O MacCare só analisa o que você autorizar."
        case .restrictedBySandbox:
            return "O App Sandbox do macOS bloqueia essa leitura. Necessita Full Disk Access."
        case .noPublicAPI:
            return "O macOS não oferece API pública e confiável para esse valor. O MacCare não inventa números."
        case .cancelled:
            return "Coleta cancelada."
        case .ioFailure:
            return "Falha de leitura durante a coleta."
        }
    }
}

/// Resultado de uma medição que pode não existir.
///
/// Usar `Measurement` em vez de `T?` + `Bool` força o chamador a lidar com
/// o caso "indisponível" na compilação, e carrega o motivo junto do valor.
public enum Measurement<Value: Sendable>: Sendable {
    case available(Value)
    case unavailable(UnavailableReason)

    public var value: Value? {
        if case .available(let value) = self { return value }
        return nil
    }

    public var isAvailable: Bool { value != nil }

    public var unavailableReason: UnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// Converte um `Optional`, classificando `nil` com o motivo informado.
    public static func from(_ value: Value?, otherwise reason: UnavailableReason) -> Measurement<Value> {
        if let value { return .available(value) }
        return .unavailable(reason)
    }

    public func map<T: Sendable>(_ transform: (Value) -> T) -> Measurement<T> {
        switch self {
        case .available(let value): return .available(transform(value))
        case .unavailable(let reason): return .unavailable(reason)
        }
    }
}

// Conformidades condicionais: `SystemSnapshot` e os modelos que embrulham
// medições precisam ser `Hashable` e `Codable`, o que só é possível quando o
// valor medido também é.
extension Measurement: Equatable where Value: Equatable {}
extension Measurement: Hashable where Value: Hashable {}
extension Measurement: Encodable where Value: Encodable {}
extension Measurement: Decodable where Value: Decodable {}
