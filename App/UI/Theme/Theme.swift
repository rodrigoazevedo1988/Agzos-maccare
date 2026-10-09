import SwiftUI

/// ## Sistema de design do Agzos MacCare
///
/// Todos os tokens visuais do aplicativo vivem aqui. Nenhuma tela define cor,
/// espaçamento ou raio por conta própria — a consequência é que o tema claro e
/// o escuro nunca divergem, e uma mudança de direção de arte é uma edição neste
/// arquivo em vez de quarenta telas.
///
/// ## Direção
///
/// Grafite e preto suave, azul elétrico como único acento, bastante ar,
/// cantos moderados e uso restrito de transparência. A referência é a
/// interface nativa do macOS bem executada, não um painel administrativo.
public enum Theme {

    // MARK: - Cores

    /// ## Por que cores dinâmicas em vez de um catálogo de assets
    ///
    /// A alternativa comum é `Color("nome", bundle:)` com um `.xcassets` cheio
    /// de Color Sets. Funciona, mas espalha a direção de arte por um editor de
    /// catálogo que ninguém versiona com clareza. Aqui a cor é código: a
    /// resolução claro/escuro acontece pelo próprio `NSColor`, e o par de
    /// valores fica visível lado a lado — revisável num diff.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let matched = appearance.bestMatch(from: [.aqua, .darkAqua])
                return matched == .darkAqua ? dark : light
            }
        )
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }

    /// Cores semânticas. Cada caso tem cor própria, e não um cinza genérico
    /// com opacidade variando — é o que permite ao tema escuro manter contraste
    /// sem reescrever as telas.
    public enum Palette {
        // Superfícies, do fundo mais profundo ao conteúdo mais elevado.
        public static let canvas = adaptive(light: rgb(246, 247, 249), dark: rgb(20, 21, 24))
        public static let surface = adaptive(light: .white, dark: rgb(30, 31, 35))
        public static let surfaceElevated = adaptive(light: .white, dark: rgb(38, 40, 45))

        // Conteúdo. O terciário existe de propósito: em uma lista com muitas
        // linhas, a hierarquia entre "o que é o nome" e "o que é o detalhe"
        // precisa de contraste, não de peso.
        public static let primaryText = adaptive(light: rgb(24, 25, 28), dark: rgb(240, 241, 244))
        public static let secondaryText = adaptive(light: rgb(94, 98, 108), dark: rgb(168, 172, 182))
        public static let tertiaryText = adaptive(light: rgb(140, 145, 155), dark: rgb(124, 128, 138))

        // Acento: azul elétrico, o único elemento saturado da interface.
        public static let accent = adaptive(light: rgb(10, 100, 232), dark: rgb(70, 145, 255))
        /// Versão translúcida para fundos de destaque e estados selecionados.
        public static let accentSubtle = accent.opacity(0.14)

        // Estados.
        public static let success = adaptive(light: rgb(24, 138, 74), dark: rgb(64, 190, 120))
        public static let warning = adaptive(light: rgb(180, 112, 8), dark: rgb(230, 165, 60))
        public static let danger = adaptive(light: rgb(192, 42, 42), dark: rgb(240, 96, 96))
        /// Cor reservada para "não disponível". Cinza de propósito: um estado
        /// ausente não é um estado de erro e não deve parecer um.
        public static let unavailable = adaptive(light: rgb(150, 154, 163), dark: rgb(110, 114, 124))

        // Estrutura.
        public static let separator = adaptive(light: rgb(228, 230, 234), dark: rgb(46, 48, 54))
        public static let border = adaptive(light: rgb(216, 219, 224), dark: rgb(52, 55, 62))
    }

    // MARK: - Espaçamento

    /// Escala de espaçamento em múltiplos de 4.
    ///
    /// Uma escala fechada é o que produz o "respiro" consistente. Espaçamento
    /// ad hoc (`padding: 13`) é a origem número um de interface que parece
    /// "quase certa" mas nunca encaixa.
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }

    // MARK: - Tipografia

    public enum Typography {
        public static let displayLarge = Font.system(size: 40, weight: .semibold, design: .default)
        public static let displayMedium = Font.system(size: 30, weight: .semibold)
        public static let titleLarge = Font.system(size: 22, weight: .semibold)
        public static let titleMedium = Font.system(size: 17, weight: .semibold)
        public static let titleSmall = Font.system(size: 15, weight: .semibold)

        public static let bodyLarge = Font.system(size: 15)
        public static let body = Font.system(size: 13)
        public static let bodySmall = Font.system(size: 12)

        public static let caption = Font.system(size: 11, weight: .medium)
        public static let captionEmphasized = Font.system(size: 11, weight: .semibold)
        /// Abaixo de `caption`, para glifos de ícone dentro de células densas.
        public static let micro = Font.system(size: 10)
        public static let microEmphasized = Font.system(size: 10, weight: .semibold)
        public static let iconSmall = Font.system(size: 9, weight: .semibold)

        /// Números grandes em tabelas e no monitor.
        public static let metric = Font.system(size: 26, weight: .medium, design: .rounded)
        public static let metricSmall = Font.system(size: 17, weight: .medium, design: .rounded)

        /// Monoespaçada para caminhos de arquivo, que precisam alinhar.
        public static let path = Font.system(size: 11, design: .monospaced)
        public static let metricMono = Font.system(size: 22, weight: .medium, design: .monospaced)
    }

    // MARK: - Formas

    public enum Radius {
        public static let small: CGFloat = 6
        public static let medium: CGFloat = 10
        public static let large: CGFloat = 14
        public static let card: CGFloat = 16
    }

    // MARK: - Movimento

    /// Animações curtas e discretas.
    ///
    /// A duracao padrao e propositalmente baixa: em um app de manutenção, o
    /// usuario esta esperando resultado, nao apreciando a transicao.
    public enum Motion {
        public static let quick = Animation.easeOut(duration: 0.15)
        public static let standard = Animation.easeInOut(duration: 0.25)
        public static let gentle = Animation.spring(response: 0.35, dampingFraction: 0.85)
    }

    // MARK: - Métricas de layout

    public enum Metrics {
        public static let sidebarWidth: CGFloat = 240
        public static let minContentWidth: CGFloat = 520
        public static let minWindowWidth: CGFloat = 900
        public static let minWindowHeight: CGFloat = 600
        public static let rowHeight: CGFloat = 32
        public static let tileMinWidth: CGFloat = 180
    }
}
