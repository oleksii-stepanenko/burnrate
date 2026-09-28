import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    /// A color that switches between a light and a dark step with the system appearance.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Validated categorical palette (fixed order, light/dark steps) plus status and sequential ramps.
enum Palette {
    static let series: [Color] = [
        .adaptive(light: 0x2A78D6, dark: 0x3987E5), // blue
        .adaptive(light: 0xEB6834, dark: 0xD95926), // orange
        .adaptive(light: 0x1BAF7A, dark: 0x199E70), // aqua
        .adaptive(light: 0xEDA100, dark: 0xC98500), // yellow
        .adaptive(light: 0xE87BA4, dark: 0xD55181), // magenta
        .adaptive(light: 0x008300, dark: 0x008300), // green
        .adaptive(light: 0x4A3AA7, dark: 0x9085E9), // violet
        .adaptive(light: 0xE34948, dark: 0xE66767), // red
    ]
    static let other = Color.adaptive(light: 0xA8A7A0, dark: 0x6B6A66)

    static let good = Color(hex: 0x0CA30C)
    static let warning = Color(hex: 0xFAB219)
    static let serious = Color(hex: 0xEC835A)
    static let critical = Color(hex: 0xD03B3B)

    /// Blue magnitude ramp. On dark surfaces "more" must read brighter, so the dark steps run the other way.
    static let sequential: [Color] = zip([0xCDE2FB, 0x9EC5F4, 0x6DA7EC, 0x3987E5, 0x256ABF, 0x184F95, 0x0D366B] as [UInt32],
                                         [0x184F95, 0x1C5CAB, 0x256ABF, 0x3987E5, 0x6DA7EC, 0x9EC5F4, 0xCDE2FB] as [UInt32])
        .map { Color.adaptive(light: $0, dark: $1) }
    static let heatEmpty = Color.adaptive(light: 0xF0EFEC, dark: 0x262624)

    static let sourceColors: [Source: Color] = [.claude: series[1], .pi: series[0], .omp: series[2]]

    static func status(for percent: Double) -> (Color, String, String) {
        switch percent {
        case ..<50: (good, "checkmark.circle.fill", "OK")
        case ..<80: (warning, "exclamationmark.circle.fill", "Elevated")
        case ..<95: (serious, "exclamationmark.triangle.fill", "High")
        default: (critical, "xmark.octagon.fill", "At limit")
        }
    }
}

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch abs(d) {
        case 1_000_000_000...: return String(format: "%.2fB", d / 1e9)
        case 1_000_000...: return String(format: "%.1fM", d / 1e6)
        case 10_000...: return String(format: "%.0fK", d / 1e3)
        case 1_000...: return String(format: "%.1fK", d / 1e3)
        default: return "\(n)"
        }
    }

    static func cost(_ v: Double) -> String {
        v >= 100 ? String(format: "$%.0f", v) : v >= 1 ? String(format: "$%.2f", v) : v > 0 ? String(format: "$%.3f", v) : "$0"
    }

    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }

    static func countdown(to date: Date?) -> String {
        guard let date else { return "—" }
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }
}

/// Rounded card container used across the dashboard.
struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
