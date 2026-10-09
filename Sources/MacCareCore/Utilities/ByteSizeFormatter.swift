import Foundation

/// Formatação de tamanhos em bytes para exibição.
///
/// A conversão usa base 1024 (GiB/MiB), que é a convenção usada pelo
/// `Disk Utility`, pelo Finder e pelos padrões do sistema — não base 1000,
/// que é a convenção de fabricantes de disco. O usuário do macOS espera
/// ver "1,2 GB" e significar 1,2 GiB.
///
/// A API de formatação do sistema (`ByteCountFormatter`) foi rejeitada de
/// propósito: ela é dependente de locale e de configuração do usuário, o que
/// quebraria a estabilidade dos testes e introduziria texto traduzido dentro do
/// núcleo determinístico. A formatação vive aqui, é testável e é estável.
public enum ByteSizeFormatter {

    private static let binaryUnits: [(suffix: String, scale: Double)] = [
        ("TiB", 1_099_511_627_776),
        ("GiB", 1_073_741_824),
        ("MiB", 1_048_576),
        ("KiB", 1_024)
    ]

    /// Formata um valor em bytes usando unidades binárias.
    ///
    /// - Parameter bytes: Quantidade de bytes. Valores negativos são
    ///   tratados como zero — um tamanho negativo é sempre um dado corrompido
    ///   ou uma subtração indevida, e exibi-lo seria pior que omitir.
    /// - Returns: String como "12,4 MiB" ou, abaixo de 1 KiB, "820 bytes".
    public static func format(_ bytes: Int64, fractionDigits: Int? = nil) -> String {
        let value = max(0, bytes)
        let magnitude = Double(value)

        for (suffix, scale) in binaryUnits where magnitude >= scale {
            let scaled = magnitude / scale
            return formatNumber(scaled, fractionDigits ?? defaultDigits(for: scaled)) + " " + suffix
        }

        return "\(value) bytes"
    }

    /// Versão compacta para eixos de gráficos e células estreitas ("12,4 MB").
    public static func compact(_ bytes: Int64) -> String {
        let value = max(0, bytes)
        let magnitude = Double(value)

        for (suffix, scale) in binaryUnits where magnitude >= scale {
            let scaled = magnitude / scale
            return formatNumber(scaled, defaultDigits(for: scaled)) + " " + String(suffix.dropLast())
        }

        return "\(value) B"
    }

    /// Formata uma fração 0...1 como porcentagem ("73%").
    ///
    /// Valores fora do intervalo são fixados nos extremos em vez de gerar
    /// "1243%" — que o usuário leria como falha de medição do app.
    public static func percent(_ fraction: Double, fractionDigits: Int = 0) -> String {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        return formatNumber(clamped * 100, fractionDigits) + "%"
    }

    private static func defaultDigits(for value: Double) -> Int {
        value >= 100 ? 0 : 1
    }

    /// Separador decimal e agrupamento de milhar no padrão pt-BR, sem depender
    /// do locale do processo (que o teste controla, mas a app em campo não).
    private static func formatNumber(_ value: Double, _ digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
