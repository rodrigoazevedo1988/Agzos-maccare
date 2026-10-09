import SwiftUI

// MARK: - Cartão

/// Superfície base do aplicativo.
///
/// Existe para que nenhuma tela precise reinventar fundo, borda, raio e sombra.
/// O resultado é que a profundidade visual da interface é **uma** decisão, não
/// cinquenta.
public struct Card<Content: View>: View {

    private let content: Content
    private let padding: CGFloat
    private let elevated: Bool

    public init(
        padding: CGFloat = Theme.Spacing.lg,
        elevated: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.elevated = elevated
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: Theme.Radius.card,
                    style: .continuous
                )
                .fill(elevated ? Theme.Palette.surfaceElevated : Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: Theme.Radius.card,
                    style: .continuous
                )
                .strokeBorder(Theme.Palette.border, lineWidth: 0.5)
            )
    }
}

// MARK: - Cabeçalho de seção

public struct SectionHeader: View {

    private let title: String
    private let subtitle: String?
    private let action: (() -> Void)?
    private let actionLabel: String?

    public init(
        _ title: String,
        subtitle: String? = nil,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionLabel = actionLabel
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(Theme.Typography.titleMedium)
                    .foregroundStyle(Theme.Palette.primaryText)

                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.bodySmall)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }

            Spacer(minLength: Theme.Spacing.md)

            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.link)
                    .font(Theme.Typography.body)
            }
        }
    }
}

// MARK: - Indicador numérico

/// Um número grande com rótulo, unidade e estado de disponibilidade.
///
/// O caso `Measurement` é o heart do componente: quando o dado não existe, o
/// bloco mostra "Indisponível" em cinza com a explicação. Um "0%" em branco
/// seria uma mentira, e este é o componente onde essa mentira aconteceria.
public struct StatTile: View {

    private let title: String
    private let measurement: Measurement<String>
    private let caption: String?
    private let symbol: String
    private let tint: Color

    public init(
        _ title: String,
        symbol: String,
        tint: Color = Theme.Palette.accent,
        value: Measurement<String>,
        caption: String? = nil
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.measurement = value
        self.caption = caption
    }

    public var body: some View {
        Card(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                    Spacer(minLength: 0)
                }

                switch measurement {
                case .available(let value):
                    Text(value)
                        .font(Theme.Typography.metric)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                case .unavailable:
                    HStack(spacing: Theme.Spacing.xxs) {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Indisponível")
                            .font(Theme.Typography.caption)
                    }
                    .foregroundStyle(Theme.Palette.unavailable)
                }

                if case .unavailable(let reason) = measurement {
                    Text(reason.explanation)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .lineLimit(2)
                } else if let caption {
                    Text(caption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .lineLimit(2)
                }
            }
        }
        .frame(minWidth: Theme.Metrics.tileMinWidth)
    }
}

// MARK: - Estado vazio

/// Telas vazias explicam o próximo passo, em vez de mostrar um espaço em branco.
public struct EmptyStateView: View {

    private let symbol: String
    private let title: String
    private let message: String
    private let actionLabel: String?
    private let action: (() -> Void)?

    public init(
        symbol: String,
        title: String,
        message: String,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.Palette.unavailable)
                .padding(.bottom, Theme.Spacing.xs)

            Text(title)
                .font(Theme.Typography.titleSmall)
                .foregroundStyle(Theme.Palette.primaryText)

            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxxl)
    }
}

// MARK: - Selo

public struct Badge: View {

    private let text: String
    private let color: Color
    private let filled: Bool

    public init(_ text: String, color: Color = Theme.Palette.secondaryText, filled: Bool = false) {
        self.text = text
        self.color = color
        self.filled = filled
    }

    public var body: some View {
        Text(text)
            .font(Theme.Typography.captionEmphasized)
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? color : color.opacity(0.14))
            )
    }
}

// MARK: - Caminho de arquivo

/// Caminhos são longos, e quebrar a linha os desalinha. Monoespaçada com
/// truncamento no meio mantém o final visível — que é a parte informativa.
public struct PathLabel: View {

    private let path: String
    private let lineLimit: Int

    public init(_ path: String, lineLimit: Int = 1) {
        self.path = path
        self.lineLimit = lineLimit
    }

    public var body: some View {
        Text(path)
            .font(Theme.Typography.path)
            .foregroundStyle(Theme.Palette.tertiaryText)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

// MARK: - Anel de progresso

public struct ProgressRing: View {

    private let fraction: Double
    private let lineWidth: CGFloat
    private let tint: Color
    private let label: String?

    public init(
        fraction: Double,
        lineWidth: CGFloat = 8,
        tint: Color = Theme.Palette.accent,
        label: String? = nil
    ) {
        self.fraction = fraction
        self.lineWidth = lineWidth
        self.tint = tint
        self.label = label
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Palette.separator, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.Motion.standard, value: fraction)

            if let label {
                Text(label)
                    .font(Theme.Typography.metricSmall)
                    .foregroundStyle(Theme.Palette.primaryText)
            }
        }
    }
}

// MARK: - Botões

/// Ação principal. Uma por tela, no máximo.
public struct PrimaryActionButton: View {

    private let title: String
    private let symbol: String
    private let isBusy: Bool
    private let action: () -> Void

    public init(_ title: String, symbol: String, isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(Theme.Typography.bodyLarge)
            }
            .frame(minWidth: 150)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isBusy)
    }
}

// MARK: - Aviso de limitação

/// Exibe uma limitação técnica do macOS de forma visível e não alarmista.
///
/// Este componente existe porque a tentação oposta é forte: esconder a
/// restrição e mostrar um número qualquer. O PRD §6 e §15 são categóricos
/// contra isso, e acredibilidade se ganha mostrando a trava.
public struct LimitationNotice: View {

    private let message: String
    private let severity: Severity

    public enum Severity {
        case information
        case warning
    }

    public init(_ message: String, severity: Severity = .information) {
        self.message = message
        self.severity = severity
    }

    private var color: Color {
        switch severity {
        case .information: return Theme.Palette.secondaryText
        case .warning: return Theme.Palette.warning
        }
    }

    private var symbol: String {
        switch severity {
        case .information: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .padding(.top, 1)

            Text(message)
                .font(Theme.Typography.bodySmall)
                .foregroundStyle(Theme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }
}
