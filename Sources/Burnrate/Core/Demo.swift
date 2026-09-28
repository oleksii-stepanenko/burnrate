import Foundation

/// `--demo`: synthetic but realistic data for screenshots and trying the app out.
/// Uses a throwaway database, reads no session logs, makes no network calls and
/// never touches the login item.
enum Demo {
    static let isOn = CommandLine.arguments.contains("--demo")

    static var databasePath: String {
        let path = NSTemporaryDirectory() + "burnrate-demo.sqlite"
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        return path
    }

    /// Small deterministic PRNG so every demo run (and screenshot) looks the same.
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func double() -> Double { Double(next() % 1_000_000) / 1_000_000 }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    }

    private struct Plan {
        let source: Source
        let provider: String
        let models: [String]
        let weight: Double
    }

    private static let plans: [Plan] = [
        Plan(source: .claude, provider: "anthropic", models: ["claude-opus-5-5", "claude-opus-5-5", "claude-sonnet-5"], weight: 0.62),
        Plan(source: .claude, provider: "anthropic", models: ["claude-opus-5", "claude-haiku-4-5"], weight: 0.12),
        Plan(source: .omp, provider: "openrouter", models: ["z-ai/glm-5.3", "deepseek/deepseek-v4-pro"], weight: 0.12),
        Plan(source: .omp, provider: "github-copilot", models: ["gpt-5.5", "claude-sonnet-5"], weight: 0.08),
        Plan(source: .pi, provider: "openrouter", models: ["moonshotai/kimi-latest", "tencent/hy3-preview:free"], weight: 0.06),
    ]

    private static let projects = [
        "~/code/checkout-service", "~/code/mobile-app", "~/code/design-system", "~/code/data-pipeline",
        "~/code/docs-site", "~/code/infra", "~/code/analytics-api", "~/code/cli-tools",
    ]

    private static let titles = [
        "Add retry logic to payment webhooks", "Migrate settings screen to SwiftUI", "Fix flaky login test",
        "Refactor token bucket rate limiter", "Write onboarding docs", "Upgrade Terraform providers",
        "Profile slow dashboard query", "Add dark mode to charts", "Parse CSV exports in the CLI",
        "Design system: new button variants", "Investigate memory leak in worker", "Add OpenTelemetry tracing",
        "Review PR: search pagination", "Set up preview deployments", "Clean up feature flags",
        "Improve error messages in API", "Add unit tests for invoice totals", "Localize checkout flow",
    ]

    private static let tools = ["Bash", "Read", "Edit", "Read", "Grep", "Bash", "Write", "WebFetch", "Edit", "Glob"]

    static func generate(now: Date = Date()) -> ParseOutput {
        var rng = RNG(state: 0xB0_52_A7_E5)
        var out = ParseOutput()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        // A neutral home folder, so screenshots never show the real user name.
        let home = "/Users/demo"
        var sessionNo = 0

        for daysAgo in (0..<42).reversed() {
            guard let day = cal.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            // Usage ramps up over the period, with quieter weekends.
            let intensity = (0.55 + 0.45 * Double(42 - daysAgo) / 42) * (weekend ? 0.3 : 1)
            let sessions = weekend ? rng.int(0...2) : rng.int(2...5)

            for _ in 0..<sessions {
                sessionNo += 1
                var roll = rng.double()
                let plan = plans.first { roll -= $0.weight; return roll <= 0 } ?? plans[0]
                let sessionId = String(format: "demo-%04d-%08x", sessionNo, rng.next())
                let project = rng.pick(projects).replacingOccurrences(of: "~", with: home)
                let startHour = weekend ? rng.int(10...16) : rng.pick([9, 9, 10, 10, 11, 13, 14, 14, 15, 16, 17, 20, 21])
                var ts = day.addingTimeInterval(Double(startHour * 3600 + rng.int(0...3000)))
                if ts > now { ts = now.addingTimeInterval(-Double(rng.int(600...5400))) }
                out.sessions.append(SessionMeta(id: sessionId, source: plan.source, title: rng.pick(titles), cwd: project))

                let requests = Int(Double(rng.int(25...160)) * intensity) + 3
                var context = Double(rng.int(18_000...30_000))
                for r in 0..<requests {
                    let model = r % 9 == 8 ? plan.models.last! : plan.models[0]
                    var row = UsageRow(key: "demo|\(sessionId)|\(r)", source: plan.source, sessionId: sessionId,
                                       project: project, model: model, provider: plan.provider, ts: ts.timeIntervalSince1970)
                    context = min(context + Double(rng.int(1_500...6_000)), 190_000)
                    let fresh = rng.int(800...6_000)
                    row.input = plan.source == .claude ? rng.int(2...40) : fresh
                    row.cacheRead = Int(context)
                    row.cacheWrite1h = plan.source == .claude ? fresh : 0
                    row.output = rng.int(120...2_400)
                    row.reasoning = Int(Double(row.output) * rng.double() * 0.4)
                    row.kind = r % 23 == 22 ? "subagent" : "main"
                    if plan.source != .claude {
                        // pi/omp report their own cost; free models report 0.
                        let paid = !model.hasSuffix(":free") && plan.provider != "github-copilot"
                        row.reportedCost = paid ? (Double(row.input) * 0.6 + Double(row.output) * 2.2 + Double(row.cacheRead) * 0.06) / 1_000_000 : 0
                    }
                    out.usage.append(row)
                    for t in 0..<rng.int(0...2) {
                        out.tools.append(ToolCallRow(key: "demo|\(sessionId)|\(r)|\(t)", ts: ts.timeIntervalSince1970,
                                                     source: plan.source, sessionId: sessionId, tool: rng.pick(tools)))
                    }
                    ts = ts.addingTimeInterval(Double(rng.int(15...140)))
                    if ts > now { break }
                }
            }
        }
        return out
    }

    /// Quota readings for the last day and a half, so the Limits history chart has shape.
    static func snapshots(now: Date = Date()) -> [(Date, String, LimitWindow)] {
        var out: [(Date, String, LimitWindow)] = []
        let start = now.addingTimeInterval(-36 * 3600)
        var t = start
        while t <= now {
            let hoursIn = t.timeIntervalSince(start) / 3600
            // 5-hour window: climbs during working hours, resets every 5h.
            let phase = hoursIn.truncatingRemainder(dividingBy: 5) / 5
            let hour = Calendar.current.component(.hour, from: t)
            let active = (9...21).contains(hour)
            let session = active ? min(95, phase * 88 + 4) : 3
            let weekly = 41 + hoursIn * 0.62
            out.append((t, "claude", LimitWindow(id: "five_hour", label: "Current session · 5h", percent: session, resetsAt: nil)))
            out.append((t, "claude", LimitWindow(id: "seven_day", label: "Weekly · all models", percent: weekly, resetsAt: nil)))
            out.append((t, "copilot", LimitWindow(id: "copilot|premium_interactions", label: "Premium requests · monthly",
                                                  percent: 30 + hoursIn * 0.19, resetsAt: nil)))
            out.append((t, "openRouter", LimitWindow(id: "openrouter|credits|omp", label: "Account credits used",
                                                     percent: 48 + hoursIn * 0.25, resetsAt: nil)))
            t = t.addingTimeInterval(20 * 60)
        }
        return out
    }

    static func providers(now: Date = Date()) -> [ProviderKind: ProviderStatus] {
        let cal = Calendar.current
        func inHours(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }
        var claude = ProviderStatus(kind: .claude, plan: "Max", fetchedAt: now.addingTimeInterval(-40), via: "Claude Code login")
        claude.windows = [
            LimitWindow(id: "five_hour", label: "Current session · 5h", percent: 42, resetsAt: inHours(2.6)),
            LimitWindow(id: "seven_day", label: "Weekly · all models", percent: 63, resetsAt: inHours(70)),
            LimitWindow(id: "seven_day_opus", label: "Weekly · Opus", percent: 71, resetsAt: inHours(70)),
        ]
        claude.facts = [Fact(label: "Extra usage", value: "Off")]

        var copilot = ProviderStatus(kind: .copilot, plan: "Pro+", account: "octocat", fetchedAt: now.addingTimeInterval(-95), via: "omp login")
        var premium = LimitWindow(id: "copilot|premium_interactions", label: "Premium requests · monthly", percent: 36.9,
                                  resetsAt: cal.date(byAdding: .day, value: 12, to: now))
        premium.detail = "554 of 1,500 used"
        copilot.windows = [premium]
        copilot.facts = [Fact(label: "Unlimited", value: "Code completions, Chat")]

        var openRouter = ProviderStatus(kind: .openRouter, plan: "Pay as you go", fetchedAt: now.addingTimeInterval(-95), via: "omp key")
        var credits = LimitWindow(id: "openrouter|credits|omp", label: "Account credits used", percent: 57, resetsAt: nil)
        credits.detail = "$28.50 of $50.00 · top up at openrouter.ai/credits"
        var free = LimitWindow(id: "openrouter|free_daily|omp", label: "Free-model requests · daily", percent: 14,
                               resetsAt: cal.date(byAdding: .hour, value: 9, to: now))
        free.detail = "140 of 1000 requests"
        openRouter.windows = [credits, free]
        openRouter.facts = [Fact(label: "Balance", value: "$21.50"), Fact(label: "Spent", value: "$1.84 today · $9.20 week · $28.50 month")]
        return [.claude: claude, .copilot: copilot, .openRouter: openRouter]
    }
}
