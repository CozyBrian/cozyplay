import SwiftUI

// MARK: - Color tokens

/// The Cozy palette shared with CozyFinance: a blue OKLCH-derived scale with a
/// warm coral for alerts, mapped to macOS dynamic appearances.
enum CozyColor {
    /// Window background: cozy50 (light) / deep navy (dark).
    static let background = dynamic(
        light: NSColor(srgbRed: 0.9530, green: 0.9647, blue: 0.9882, alpha: 1),
        dark: NSColor(srgbRed: 0.0313, green: 0.0588, blue: 0.0902, alpha: 1)
    )

    /// Card surface: white (light) / cozy900 (dark).
    static let surface = dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.1294, green: 0.2274, blue: 0.3490, alpha: 1)
    )

    /// Wells, meter tracks, and hover fills: cozy100 (light) / cozy800 (dark).
    static let surfaceSecondary = dynamic(
        light: NSColor(srgbRed: 0.9019, green: 0.9333, blue: 0.9726, alpha: 1),
        dark: NSColor(srgbRed: 0.1332, green: 0.2667, blue: 0.4158, alpha: 1)
    )

    /// Brand blue: cozy500 (light) / cozy400 (dark).
    static let tint = dynamic(
        light: NSColor(srgbRed: 0.2393, green: 0.4863, blue: 0.7293, alpha: 1),
        dark: NSColor(srgbRed: 0.3804, green: 0.6000, blue: 0.8118, alpha: 1)
    )

    /// Warm coral for errors and destructive actions.
    static let accent = dynamic(
        light: NSColor(srgbRed: 0.8524, green: 0.3212, blue: 0.3445, alpha: 1),
        dark: NSColor(srgbRed: 0.9389, green: 0.4931, blue: 0.4941, alpha: 1)
    )

    /// Live / connected states.
    static let success = dynamic(
        light: NSColor(srgbRed: 0.0667, green: 0.7255, blue: 0.5059, alpha: 1),
        dark: NSColor(srgbRed: 0.1804, green: 0.7804, blue: 0.5765, alpha: 1)
    )

    /// Primary text: cozy900 (light) / cozy50 (dark).
    static let textPrimary = dynamic(
        light: NSColor(srgbRed: 0.1294, green: 0.2274, blue: 0.3490, alpha: 1),
        dark: NSColor(srgbRed: 0.9530, green: 0.9647, blue: 0.9882, alpha: 1)
    )

    /// Secondary text: cozy700 (light) / cozy200 (dark).
    static let textSecondary = dynamic(
        light: NSColor(srgbRed: 0.1450, green: 0.3058, blue: 0.4980, alpha: 1),
        dark: NSColor(srgbRed: 0.7842, green: 0.8588, blue: 0.9373, alpha: 1)
    )

    /// Hairline borders and rack separators.
    static let border = dynamic(
        light: NSColor(srgbRed: 0.1294, green: 0.2274, blue: 0.3490, alpha: 0.10),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
    )

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Type, spacing, and radius tokens

enum CozyFont {
    static let hero = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let railTitle = Font.system(.title, design: .rounded, weight: .bold)
    static let title = Font.system(.title2, design: .rounded, weight: .semibold)
    static let sectionTitle = Font.system(.headline, design: .rounded, weight: .semibold)
    static let body = Font.system(.body, design: .rounded)
    static let detail = Font.system(.subheadline, design: .rounded)
    static let caption = Font.system(.caption, design: .rounded, weight: .medium)
}

enum CozySpacing {
    static let xSmall: CGFloat = 8
    static let small: CGFloat = 12
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
}

enum CozyRadius {
    static let small: CGFloat = 12
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
}

// MARK: - Surfaces

/// The CozyFinance card: solid surface, hairline border, one soft shadow.
struct CozyCard: ViewModifier {
    var padding: CGFloat = CozySpacing.medium
    var radius: CGFloat = CozyRadius.medium

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(CozyColor.surface, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(CozyColor.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.07), radius: 14, x: 0, y: 5)
    }
}

/// Liquid Glass on macOS 26, a plain material before it.
struct AdaptiveGlass: ViewModifier {
    var radius: CGFloat = CozyRadius.medium

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: radius))
        }
    }
}

extension View {
    func cozyCard(padding: CGFloat = CozySpacing.medium, radius: CGFloat = CozyRadius.medium) -> some View {
        modifier(CozyCard(padding: padding, radius: radius))
    }

    /// A full-width card that stacks flush rack rows (channel strips, slots).
    func cozyRack() -> some View {
        clipShape(.rect(cornerRadius: CozyRadius.medium))
            .cozyCard(padding: 0)
    }

    func adaptiveGlass(radius: CGFloat = CozyRadius.medium) -> some View {
        modifier(AdaptiveGlass(radius: radius))
    }

    func rackRowHover() -> some View {
        modifier(RackRowHover())
    }
}

/// Quiet hover fill for interactive rack rows.
struct RackRowHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? CozyColor.surfaceSecondary.opacity(0.45) : .clear)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Inset hairline between rack rows; inset aligns with text past a leading chip.
struct CozyRackSeparator: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(CozyColor.border)
            .frame(height: 1)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

// MARK: - Atoms

/// Rounded-square symbol on a soft tint fill; the CozyFinance chip.
struct CozyIconChip: View {
    let systemImage: String
    var color: Color = CozyColor.tint
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: .rect(cornerRadius: size * 0.32))
            .accessibilityHidden(true)
    }
}

/// Capsule status pill: dot + label on a soft tint fill.
struct CozyStatusChip: View {
    let text: String
    var color: Color = CozyColor.success

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(CozyFont.caption)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// Engraved console label: small caps over the rack it introduces.
struct CozySectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(CozyFont.caption)
                .kerning(1.1)
                .textCase(.uppercase)
                .foregroundStyle(CozyColor.textSecondary.opacity(0.85))
            Spacer()
            if let detail {
                Text(detail)
                    .font(CozyFont.caption)
                    .foregroundStyle(CozyColor.textSecondary)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Segmented level meter driven by the live capture level, like a receiver face.
struct CozyVUMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let level: Float
    let active: Bool
    var barCount = 26
    var barHeight: CGFloat = 22

    private var litBars: Int {
        guard active else { return 0 }
        let clamped = max(0, min(1, level))
        return max(1, Int((Float(barCount) * clamped).rounded()))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < litBars ? CozyColor.success : CozyColor.surfaceSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: barHeight)
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: litBars)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(active ? "Audio level" : "Audio capture is inactive")
        .accessibilityValue(active ? "\(Int(max(0, min(1, level)) * 100)) percent" : "")
    }
}

struct CozyErrorBanner: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(CozyFont.detail)
                .foregroundStyle(CozyColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(CozyColor.accent)
        }
        .padding(CozySpacing.small + 2)
        .background(CozyColor.accent.opacity(0.10), in: .rect(cornerRadius: CozyRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: CozyRadius.small)
                .strokeBorder(CozyColor.accent.opacity(0.25), lineWidth: 1)
        }
    }
}
