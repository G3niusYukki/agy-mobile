import SwiftUI
import UIKit
import AgyMobileCore

// MARK: - Antigravity Mobile 极简曜石 / 钛银主题（去 AI 紫）

enum Theme {
    /// 主强调色：浅色为哑光曜石黑，深色为纯钛白（Codex / Claude / Apple Pro 质感）
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.955, blue: 0.965, alpha: 1)
            : UIColor(red: 0.10, green: 0.105, blue: 0.12, alpha: 1)
    })

    /// 主强调按钮上的前景色（浅色白字 / 深色黑字）
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.07, green: 0.075, blue: 0.085, alpha: 1)
            : UIColor.white
    })

    static let indigo = accent
    static let cyan = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.76, green: 0.78, blue: 0.82, alpha: 1)
            : UIColor(red: 0.32, green: 0.34, blue: 0.39, alpha: 1)
    })
    static let mist = Color.primary.opacity(0.65)
    static let success = Color(red: 0.14, green: 0.68, blue: 0.38)
    static let amber = Color(red: 0.92, green: 0.60, blue: 0.10)
    static let coral = Color(red: 0.88, green: 0.28, blue: 0.26)

    static let bgSolid = Color(uiColor: .systemBackground)
    static let sidebarBG = Color(uiColor: .secondarySystemBackground)
    static let inputFill = Color.primary.opacity(0.055)

    static let cardFill = Color.primary.opacity(0.045)
    static let cardFillStrong = Color.primary.opacity(0.085)
    static let cardStroke = Color.primary.opacity(0.11)

    static let accentFill = accent
    static let accentGradient = LinearGradient(
        colors: [accent, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.primary.opacity(0.42)

    static func background() -> some View { AgyBackground() }
}

struct AgyBackground: View {
    var body: some View {
        Theme.bgSolid.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

// MARK: - 液态玻璃

struct GlassSurface: ViewModifier {
    let radius: CGFloat
    let tint: Color?
    let clear: Bool
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(resolvedGlass, in: .rect(cornerRadius: radius))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(tint ?? .clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
                )
        }
    }

    @available(iOS 26.0, *)
    private var resolvedGlass: Glass {
        var glass: Glass = clear ? .clear : .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    func agyGlassCard(radius: CGFloat = 20, tint: Color? = nil, clear: Bool = false, interactive: Bool = false) -> some View {
        modifier(GlassSurface(radius: radius, tint: tint, clear: clear, interactive: interactive))
    }
}

// MARK: - 品牌标志（极简曜石/钛银几何徽标）

struct AgyMark: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.accent)
            AgyChevronShape()
                .fill(Theme.onAccent)
                .frame(width: size * 0.50, height: size * 0.56)
                .offset(y: -size * 0.01)
        }
        .frame(width: size, height: size)
    }
}

private struct AgyChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX * 0.82, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.height * 0.62))
        p.addLine(to: CGPoint(x: rect.maxX * 0.18, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct AgyWordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            AgyMark(size: 30).accessibilityHidden(true)
            Text("Antigravity")
                .appFont(.title3.bold())
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - 通用控件

struct AgyIconButton: View {
    let systemName: String
    var tint: Color = Theme.textPrimary
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .appFont(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}

struct AgySearchField: View {
    @Binding var text: String
    var placeholder: String = "搜索会话"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(bouncy())
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 状态点（带呼吸光晕，尊重 Reduce Motion 且支持动态切换）
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8
    var pulsing: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 1.2)
                    .scaleEffect(1 + phase * 2.1)
                    .opacity(pulsing && !reduceMotion ? 1 - phase : 0)
            )
            .onAppear { syncPulse() }
            .onChange(of: pulsing) { _, _ in syncPulse() }
            .onChange(of: reduceMotion) { _, _ in syncPulse() }
    }

    private func syncPulse() {
        phase = 0
        guard pulsing, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

struct bouncy: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
