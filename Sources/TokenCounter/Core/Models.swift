import Foundation

enum Source: String, CaseIterable, Identifiable, Sendable, Hashable {
    case claude, pi, omp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .pi: "pi"
        case .omp: "omp"
        }
    }

    var shortLabel: String { self == .claude ? "Claude" : label }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .pi: "p.circle"
        case .omp: "o.circle"
        }
    }
}

/// One billed model response (or one advisor sub-call) parsed from a session log.
struct UsageRow: Sendable {
    var key: String
    var source: Source
    var sessionId: String
    var project: String
    var model: String
    var provider: String
    var ts: Double
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var reasoning = 0
    /// Cost reported by the tool itself; nil means "estimate from the price table".
    var reportedCost: Double?
    var fast = false
    var kind = "main"
    var isError = false
}

struct ToolCallRow: Sendable {
    var key: String
    var ts: Double
    var source: Source
    var sessionId: String
    var tool: String
}

struct SessionMeta: Sendable {
    var id: String
    var source: Source
    var title: String?
    var cwd: String?
}

enum ModelNames {
    /// Canonical key used for grouping, so "claude-opus-4.6" (Copilot) and
    /// "claude-opus-4-6" (Claude Code) land in the same bucket.
    static func canonical(_ raw: String) -> String {
        var m = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if m.hasPrefix("~") { m.removeFirst() }
        for prefix in ["anthropic/", "anthropic.", "us.anthropic.", "eu.anthropic."] where m.hasPrefix(prefix) {
            m.removeFirst(prefix.count)
        }
        if m.hasPrefix("claude-") {
            m = m.replacingOccurrences(of: ".", with: "-")
            // Strip date snapshots like -20250929 and trailing [1m] context tags.
            if let r = m.range(of: #"-20\d{6}$"#, options: .regularExpression) { m.removeSubrange(r) }
            if let r = m.range(of: #"\[.*\]$"#, options: .regularExpression) { m.removeSubrange(r) }
        }
        return m
    }

    /// Human label: "claude-opus-5-5" -> "Opus 5.5", "z-ai/glm-5.3" -> "glm-5.3".
    static func display(_ model: String) -> String {
        if model.hasPrefix("claude-") {
            let parts = model.dropFirst("claude-".count).split(separator: "-")
            guard let family = parts.first else { return model }
            let version = parts.dropFirst().joined(separator: ".")
            return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
        }
        if let slash = model.lastIndex(of: "/") { return String(model[model.index(after: slash)...]) }
        return model
    }
}

/// API-equivalent list prices (USD per million tokens) used to estimate what
/// Claude Code usage would cost at pay-as-you-go rates. Claude Code logs don't
/// record cost, and a subscription isn't billed per token, so this is a yardstick.
enum Pricing {
    struct Rate {
        let input: Double
        let output: Double
        let cacheRead: Double
        var write5m: Double { input * 1.25 }
        var write1h: Double { input * 2 }
    }

    /// First match wins, so more specific prefixes come first.
    static let table: [(prefix: String, rate: Rate)] = [
        ("claude-fable-5-1", Rate(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Rate(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable", Rate(input: 10, output: 50, cacheRead: 1.0)),
        ("claude-mythos", Rate(input: 10, output: 50, cacheRead: 1.0)),
        ("claude-opus-5-5", Rate(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", Rate(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-8", Rate(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-7", Rate(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-6", Rate(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-5", Rate(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4", Rate(input: 15, output: 75, cacheRead: 1.50)),
        ("claude-sonnet-5", Rate(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet", Rate(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-3-7-sonnet", Rate(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-3-5-sonnet", Rate(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-4", Rate(input: 1, output: 5, cacheRead: 0.10)),
        ("claude-3-5-haiku", Rate(input: 0.8, output: 4, cacheRead: 0.08)),
        ("claude-haiku", Rate(input: 0.8, output: 4, cacheRead: 0.08)),
    ]

    static func rate(for model: String) -> Rate? {
        table.first { model.hasPrefix($0.prefix) }?.rate
    }

    static let fastMultiplier = 2.0
}
