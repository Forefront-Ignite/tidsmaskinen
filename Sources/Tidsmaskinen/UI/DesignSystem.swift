import SwiftUI

// ===================================================================
// Tidsmaskinen — Liquid Glass design system.
//
// Native re-creation of the "Tidsmaskinen Liquid Glass Edition" design
// handoff (see plans/liquid-glass-redesign.md). Tokens, the segmented-
// clock app mark, glass surface modifiers, and the theme setting all
// live here so every view composes from one vocabulary.
// ===================================================================

// MARK: - Tokens

enum TM {
    /// Brand accent — the prototype's `--accent: #5b54ff`.
    static let accent = Color(hex: "#5b54ff") ?? .blue
    static let accentSoft = Color.accentColor.opacity(0.14)

    /// Customer color palette used by the app mark's segmented ring
    /// (prototype `MARK_ARCS`). Real customer colors come from the DB;
    /// this is only the identity mark's default ring.
    static let markArcs: [Color] = [
        Color(hex: "#8b5cf6") ?? .purple,
        Color(hex: "#10b981") ?? .green,
        Color(hex: "#f59e0b") ?? .orange,
        Color(hex: "#6366f1") ?? .indigo,
    ]

    /// Positive delta / "attributed" green.
    static let positive = Color(hex: "#10b981") ?? .green

    // Corner radii (prototype `--r: 22px`, cards 16, pills 13).
    static let radiusCard: CGFloat = 18
    static let radiusInner: CGFloat = 13
    static let radiusPill: CGFloat = 11
}

// MARK: - Hex color

extension Color {
    init?(hex: String?) {
        guard let hex = hex?.trimmingCharacters(in: .whitespacesAndNewlines), hex.hasPrefix("#"),
              hex.count == 7 else { return nil }
        let scanner = Scanner(string: String(hex.dropFirst()))
        var rgb: UInt64 = 0
        guard scanner.scanHexInt64(&rgb) else { return nil }
        self = Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

// MARK: - Theme setting

/// User-selectable appearance. `system` follows macOS.
enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }

    var label: String {
        switch self {
        case .light:  return "Light"
        case .dark:   return "Dark"
        case .system: return "Auto"
        }
    }

    var symbol: String {
        switch self {
        case .light:  return "sun.max"
        case .dark:   return "moon"
        case .system: return "desktopcomputer"
        }
    }

    /// nil = follow the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }
}

extension SettingsKey {
    static let appearance = "appearance"
}

extension AppSettings {
    static var appearance: AppTheme {
        guard let raw = defaults.string(forKey: SettingsKey.appearance),
              let value = AppTheme(rawValue: raw) else { return .system }
        return value
    }
}

// MARK: - Glass surfaces

/// A frosted card surface — the workhorse container of the redesign.
/// Uses native Liquid Glass on macOS 26.
struct GlassCard: ViewModifier {
    var radius: CGFloat = TM.radiusCard
    var padding: CGFloat? = nil

    func body(content: Content) -> some View {
        let shaped = content
            .padding(padding.map { EdgeInsets(top: $0, leading: $0, bottom: $0, trailing: $0) } ?? EdgeInsets())
        return shaped
            .glassEffect(.regular, in: .rect(cornerRadius: radius))
    }
}

/// A soft inner chip / control surface (pills, steppers, segmented bg).
struct GlassChip: ViewModifier {
    var radius: CGFloat = TM.radiusPill
    func body(content: Content) -> some View {
        content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: radius))
    }
}

extension View {
    /// Frosted card container with optional internal padding.
    func glassCard(radius: CGFloat = TM.radiusCard, padding: CGFloat? = nil) -> some View {
        modifier(GlassCard(radius: radius, padding: padding))
    }

    /// Soft interactive chip surface.
    func glassChip(radius: CGFloat = TM.radiusPill) -> some View {
        modifier(GlassChip(radius: radius))
    }
}

// MARK: - App mark (segmented-clock identity)

/// The Tidsmaskinen identity mark: a clock built from a segmented ring —
/// a donut split into colored arcs with a clock hand at the center.
/// Renders three ways: colorful (app icon), white-on-accent (rail), and
/// monochrome (menu-bar tray glyph), by varying `arcs` / `hand`.
struct AppMark: View {
    var arcs: [Color] = TM.markArcs
    var hand: Color = .primary
    var size: CGFloat = 24

    var body: some View {
        Canvas { ctx, dim in
            let s = min(dim.width, dim.height)
            let center = CGPoint(x: dim.width / 2, y: dim.height / 2)
            let r = s * 0.34
            let lw = s * 0.11
            let gap = 20.0                      // degrees of gap between segments
            let seg = 90.0 - gap

            for i in 0..<4 {
                let base = -90.0 + Double(i) * 90.0 + gap / 2
                var path = Path()
                path.addArc(center: center, radius: r,
                            startAngle: .degrees(base),
                            endAngle: .degrees(base + seg),
                            clockwise: false)
                let color = arcs.isEmpty ? hand : arcs[i % arcs.count]
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }

            // Clock hands (hour up, minute to lower-right) + center hub.
            let handW = s * 0.065
            var hour = Path()
            hour.move(to: center)
            hour.addLine(to: CGPoint(x: center.x, y: center.y - r * 0.56))
            ctx.stroke(hour, with: .color(hand), style: StrokeStyle(lineWidth: handW, lineCap: .round))

            var minute = Path()
            minute.move(to: center)
            minute.addLine(to: CGPoint(x: center.x + r * 0.38, y: center.y + r * 0.2))
            ctx.stroke(minute, with: .color(hand), style: StrokeStyle(lineWidth: handW, lineCap: .round))

            let hub = s * 0.05
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)),
                     with: .color(hand))
        }
        .frame(width: size, height: size)
    }

    /// The colorful identity squircle used for the app icon / brand chip.
    static func badge(size: CGFloat = 34) -> some View {
        AppMark(arcs: TM.markArcs, hand: .primary, size: size * 0.62)
            .frame(width: size, height: size)
            .glassEffect(.regular, in: .rect(cornerRadius: size * 0.3))
    }
}

// MARK: - Wallpaper

/// Soft, theme-aware backdrop behind the main views so the frosted glass
/// cards have a colorful surface to refract — the native, calmer reading of
/// the prototype's animated wallpaper. Static (no animation) for a utility
/// window; the corners echo the design's peach / sky / violet / mint mesh.
struct TMWallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tints: [(Color, UnitPoint)] = scheme == .dark
            ? [(Color(hex: "#3a2a52") ?? .purple, .topLeading),
               (Color(hex: "#1d3358") ?? .blue, .topTrailing),
               (Color(hex: "#3a2056") ?? .purple, .bottomTrailing),
               (Color(hex: "#123f35") ?? .green, .bottomLeading)]
            : [(Color(hex: "#ffe0c4") ?? .orange, .topLeading),
               (Color(hex: "#cfdcff") ?? .blue, .topTrailing),
               (Color(hex: "#e7ccff") ?? .purple, .bottomTrailing),
               (Color(hex: "#c5f4e2") ?? .green, .bottomLeading)]
        ZStack {
            (scheme == .dark ? Color(hex: "#0d0e16") : Color(hex: "#eef1fb"))
            ForEach(Array(tints.enumerated()), id: \.offset) { _, tint in
                RadialGradient(
                    colors: [tint.0.opacity(scheme == .dark ? 0.45 : 0.7), .clear],
                    center: tint.1, startRadius: 0, endRadius: 520)
            }
        }
        .opacity(scheme == .dark ? 0.6 : 0.55)
    }
}

extension View {
    /// Place the soft glass wallpaper behind a full-bleed view.
    func tmWallpaper() -> some View {
        background(TMWallpaper().ignoresSafeArea())
    }
}

// MARK: - Small reusable bits

/// A colored status dot (customer/project bead).
struct ColorDot: View {
    var color: Color
    var size: CGFloat = 9
    var square: Bool = false
    var body: some View {
        RoundedRectangle(cornerRadius: square ? size * 0.38 : size / 2, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// Command Center (read-only) vs LOCAL (editable) chip.
struct SourceChip: View {
    var isCommandCenter: Bool
    var body: some View {
        if isCommandCenter {
            Label("CC", systemImage: "building.2.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: .rect(cornerRadius: 6))
        } else {
            Text("LOCAL")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(TM.accent)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(TM.accentSoft, in: .rect(cornerRadius: 6))
        }
    }
}
