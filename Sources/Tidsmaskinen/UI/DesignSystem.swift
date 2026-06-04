import SwiftUI
import AppKit

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
    static let reviewMinMinutes = "reviewMinMinutes"
}

extension AppSettings {
    static var appearance: AppTheme {
        guard let raw = defaults.string(forKey: SettingsKey.appearance),
              let value = AppTheme(rawValue: raw) else { return .system }
        return value
    }

    /// Review hides items shorter than this many minutes (default 1 — hides 0-min noise).
    static var reviewMinMinutes: Int {
        if defaults.object(forKey: SettingsKey.reviewMinMinutes) == nil { return 1 }
        return max(0, defaults.integer(forKey: SettingsKey.reviewMinMinutes))
    }
}

// MARK: - Attribution scope

/// Shared "how long does this attribution apply" choice, used by Review,
/// Discover, Calls and My day. `justThis` is a precise per-occurrence override
/// (no rule); `today`/`thisWeek` create a time-bounded rule; `always` a
/// permanent rule.
enum AttributionScope: String, CaseIterable, Identifiable {
    case justThis, today, thisWeek, always
    var id: String { rawValue }

    var label: String {
        switch self {
        case .justThis: return "Just this"
        case .today:    return "Today"
        case .thisWeek: return "This week"
        case .always:   return "Always"
        }
    }

    /// Whether choosing this scope writes a reusable rule (vs a one-off override).
    var createsRule: Bool { self != .justThis }

    /// Rule validity window relative to a reference date (the day being viewed).
    /// `justThis`/`always` are unbounded (justThis never reaches rule creation).
    func bounds(reference: Date) -> (Date?, Date?) {
        let cal = Calendar.weekStartingMonday()
        switch self {
        case .justThis, .always:
            return (nil, nil)
        case .today:
            let s = cal.startOfDay(for: reference)
            return (s, cal.date(byAdding: .day, value: 1, to: s) ?? s)
        case .thisWeek:
            if let wk = cal.dateInterval(of: .weekOfYear, for: reference) {
                return (wk.start, wk.end)
            }
            return (nil, nil)
        }
    }
}

/// Segmented scope control shared across the attribution surfaces.
struct AttributionScopePicker: View {
    @Binding var scope: AttributionScope
    var options: [AttributionScope]
    /// Short hint shown under the picker; pass the period label (e.g. "Wed 4 Jun").
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("", selection: $scope) {
                ForEach(options) { s in Text(s.label).tag(s) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.tertiary)
            }
        }
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

    /// Monochrome template image of the mark for the menu-bar tray. A SwiftUI
    /// `Canvas` doesn't render as a `MenuBarExtra` label, so we draw an NSImage
    /// and mark it `isTemplate` so macOS tints it for the menu bar appearance.
    static let trayImage: NSImage = {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        let center = CGPoint(x: s / 2, y: s / 2)
        let r = s * 0.34
        let lw = s * 0.13
        let gap = 22.0
        let seg = 90.0 - gap
        NSColor.black.setStroke()
        for i in 0..<4 {
            let start = Double(i) * 90.0 + gap / 2
            let p = NSBezierPath()
            p.appendArc(withCenter: center, radius: r, startAngle: start, endAngle: start + seg, clockwise: false)
            p.lineWidth = lw
            p.lineCapStyle = .round
            p.stroke()
        }
        let handW = s * 0.085
        NSColor.black.setStroke()
        let hour = NSBezierPath()
        hour.move(to: center); hour.line(to: CGPoint(x: center.x, y: center.y + r * 0.56))
        hour.lineWidth = handW; hour.lineCapStyle = .round; hour.stroke()
        let minute = NSBezierPath()
        minute.move(to: center); minute.line(to: CGPoint(x: center.x + r * 0.40, y: center.y - r * 0.22))
        minute.lineWidth = handW; minute.lineCapStyle = .round; minute.stroke()
        let hub = s * 0.075
        NSColor.black.setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)).fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }()

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
            ? [(Color(hex: "#4a3370") ?? .purple, .topLeading),
               (Color(hex: "#1d4d8a") ?? .blue, .topTrailing),
               (Color(hex: "#4a1f6e") ?? .purple, .bottomTrailing),
               (Color(hex: "#13503f") ?? .green, .bottomLeading)]
            : [(Color(hex: "#ffd9b0") ?? .orange, .topLeading),
               (Color(hex: "#bcd0ff") ?? .blue, .topTrailing),
               (Color(hex: "#e3bcff") ?? .purple, .bottomTrailing),
               (Color(hex: "#b0f0d8") ?? .green, .bottomLeading)]
        ZStack {
            (scheme == .dark ? Color(hex: "#0c0d15") : Color(hex: "#eef1fb"))
            ForEach(Array(tints.enumerated()), id: \.offset) { _, tint in
                RadialGradient(
                    colors: [tint.0.opacity(scheme == .dark ? 0.6 : 0.9), .clear],
                    center: tint.1, startRadius: 0, endRadius: 620)
            }
        }
    }
}

extension View {
    /// Place the soft glass wallpaper behind a full-bleed view.
    func tmWallpaper() -> some View {
        background(TMWallpaper().ignoresSafeArea())
    }
}

// MARK: - Design icons

/// Line/fill icons ported from the prototype's `Icon` SVG set (24×24 space),
/// so the app uses one consistent icon language instead of mixed SF Symbols.
struct DesignIcon: View {
    let name: String
    var size: CGFloat = 20
    var color: Color = .primary

    var body: some View {
        Canvas { ctx, dim in
            let s = dim.width / 24
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let shade = GraphicsContext.Shading.color(color)
            let stroke = StrokeStyle(lineWidth: 1.9 * s, lineCap: .round, lineJoin: .round)
            func line(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> Path {
                var p = Path(); p.move(to: P(a.0, a.1)); p.addLine(to: P(b.0, b.1)); return p
            }
            func strokePath(_ build: (inout Path) -> Void) {
                var p = Path(); build(&p); ctx.stroke(p, with: shade, style: stroke)
            }

            switch name {
            case "report":
                ctx.stroke(line((5, 21), (5, 10)), with: shade, style: stroke)
                ctx.stroke(line((12, 21), (12, 4)), with: shade, style: stroke)
                ctx.stroke(line((19, 21), (19, 14)), with: shade, style: stroke)
            case "review":
                strokePath { p in
                    p.move(to: P(3, 7)); p.addLine(to: P(12, 3)); p.addLine(to: P(21, 7))
                    p.addLine(to: P(12, 11)); p.closeSubpath()
                }
                strokePath { p in p.move(to: P(3, 12)); p.addLine(to: P(12, 16)); p.addLine(to: P(21, 12)) }
                strokePath { p in p.move(to: P(3, 17)); p.addLine(to: P(12, 21)); p.addLine(to: P(21, 17)) }
            case "myday":
                strokePath { p in p.addRoundedRect(in: CGRect(x: 3 * s, y: 4.5 * s, width: 18 * s, height: 16 * s), cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s)) }
                ctx.stroke(line((3, 9), (21, 9)), with: shade, style: stroke)
                ctx.stroke(line((8, 3), (8, 6)), with: shade, style: stroke)
                ctx.stroke(line((16, 3), (16, 6)), with: shade, style: stroke)
                ctx.stroke(line((7.5, 13), (11.5, 13)), with: shade, style: stroke)
                ctx.stroke(line((7.5, 16.5), (14.5, 16.5)), with: shade, style: stroke)
            case "discover":
                for r in [CGRect(x: 4, y: 4, width: 7, height: 7), CGRect(x: 13, y: 4, width: 7, height: 7),
                          CGRect(x: 4, y: 13, width: 7, height: 7), CGRect(x: 13, y: 13, width: 7, height: 7)] {
                    strokePath { p in p.addRoundedRect(in: CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s), cornerSize: CGSize(width: 1.6 * s, height: 1.6 * s)) }
                }
            case "people":
                strokePath { p in p.addEllipse(in: CGRect(x: (9 - 3.2) * s, y: (8 - 3.2) * s, width: 6.4 * s, height: 6.4 * s)) }
                strokePath { p in p.move(to: P(3.5, 19)); p.addQuadCurve(to: P(14.5, 19), control: P(9, 12.5)) }
                strokePath { p in p.move(to: P(16, 5.4)); p.addQuadCurve(to: P(16, 10.6), control: P(18.6, 8)) }
                strokePath { p in p.move(to: P(16.5, 19)); p.addQuadCurve(to: P(20.5, 14.5), control: P(20, 17)) }
            case "sliders":
                ctx.stroke(line((4, 7), (13, 7)), with: shade, style: stroke)
                ctx.stroke(line((17, 7), (20, 7)), with: shade, style: stroke)
                ctx.stroke(line((4, 12), (7, 12)), with: shade, style: stroke)
                ctx.stroke(line((11, 12), (20, 12)), with: shade, style: stroke)
                ctx.stroke(line((4, 17), (13, 17)), with: shade, style: stroke)
                ctx.stroke(line((19, 17), (20, 17)), with: shade, style: stroke)
                for c in [(15.0, 7.0), (9.0, 12.0), (17.0, 17.0)] {
                    strokePath { p in p.addEllipse(in: CGRect(x: (c.0 - 2.2) * s, y: (c.1 - 2.2) * s, width: 4.4 * s, height: 4.4 * s)) }
                }
            case "globe", "host":
                strokePath { p in p.addEllipse(in: CGRect(x: 3 * s, y: 3 * s, width: 18 * s, height: 18 * s)) }
                ctx.stroke(line((3, 12), (21, 12)), with: shade, style: stroke)
                strokePath { p in p.addEllipse(in: CGRect(x: (12 - 4) * s, y: 3 * s, width: 8 * s, height: 18 * s)) }
            case "repo":
                strokePath { p in p.move(to: P(8, 8)); p.addLine(to: P(4, 12)); p.addLine(to: P(8, 16)) }
                strokePath { p in p.move(to: P(16, 8)); p.addLine(to: P(20, 12)); p.addLine(to: P(16, 16)) }
            case "call":
                var p = Path()
                p.move(to: P(6.6, 10.8))
                p.addCurve(to: P(13.2, 17.4), control1: P(8, 13.6), control2: P(10.4, 15.9))
                p.addLine(to: P(15.4, 15.2)); p.addCurve(to: P(16.4, 15.0), control1: P(15.7, 14.9), control2: P(16.1, 14.8))
                p.addCurve(to: P(20, 15.6), control1: P(17.5, 15.4), control2: P(18.7, 15.6))
                p.addCurve(to: P(21, 16.6), control1: P(19.6, 15.6), control2: P(21, 16.0))
                p.addLine(to: P(21, 20)); p.addCurve(to: P(20, 21), control1: P(21, 20.6), control2: P(20.6, 21))
                p.addCurve(to: P(3, 4), control1: P(10.6, 21), control2: P(3, 13.4))
                p.addCurve(to: P(4, 3), control1: P(3, 3.4), control2: P(3.4, 3))
                p.addLine(to: P(7.5, 3)); p.addCurve(to: P(8.5, 4), control1: P(8.1, 3), control2: P(8.5, 3.4))
                p.addCurve(to: P(9.1, 7.6), control1: P(8.5, 5.2), control2: P(8.7, 6.4))
                p.addCurve(to: P(8.8, 8.6), control1: P(9.2, 8.0), control2: P(9.1, 8.4))
                p.closeSubpath()
                ctx.fill(p, with: shade)
            case "check":
                strokePath { p in p.move(to: P(5, 12.5)); p.addLine(to: P(9.5, 17)); p.addLine(to: P(19, 6.5)) }
            default:
                // Unknown name: nothing (caller should fall back to an SF Symbol).
                break
            }
        }
        .frame(width: size, height: size)
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
