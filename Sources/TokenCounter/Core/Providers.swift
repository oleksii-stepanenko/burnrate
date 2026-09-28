import Foundation

/// How often each data source is refreshed. The Help page shows these values.
enum Refresh {
    static let files: TimeInterval = 10
    static let claude: TimeInterval = 120
    static let copilot: TimeInterval = 300
    static let openRouter: TimeInterval = 300
    /// A manual refresh never hits a provider more often than this.
    static let manualMinimum: TimeInterval = 30
    static let maxBackoff: TimeInterval = 1800
}

enum ProviderKind: String, CaseIterable, Sendable {
    case claude, copilot, openRouter

    var title: String {
        switch self {
        case .claude: "Claude"
        case .copilot: "GitHub Copilot"
        case .openRouter: "OpenRouter"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .claude: Refresh.claude
        case .copilot: Refresh.copilot
        case .openRouter: Refresh.openRouter
        }
    }
}

struct Fact: Identifiable, Sendable {
    var id: String { label }
    let label: String
    let value: String
    var warning = false
}

/// Plan, quota windows and account facts for one provider, as shown in the quota cards.
struct ProviderStatus: Identifiable, Sendable {
    let kind: ProviderKind
    var id: String { kind.rawValue }
    var plan: String?
    var account: String?
    var windows: [LimitWindow] = []
    var facts: [Fact] = []
    var fetchedAt: Date?
    var error: String?
    /// Where the credentials came from, e.g. "Claude Code login".
    var via: String?

    var isEmpty: Bool { windows.isEmpty && facts.isEmpty }
}

// MARK: - Credentials stored by other tools (read-only)

enum StoredCredentials {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// `(provider, JSON data)` rows from omp's credential store.
    private static func ompCredentials() -> [(String, [String: Any])] {
        let path = home.appendingPathComponent(".omp/agent/agent.db").path
        guard FileManager.default.fileExists(atPath: path), let db = try? SQLiteDB(path: path, readOnly: true) else { return [] }
        return (try? db.query("SELECT provider, data FROM auth_credentials WHERE disabled_cause IS NULL ORDER BY updated_at DESC") { s in
            (s.string(0), (try? JSONSerialization.jsonObject(with: Data(s.string(1).utf8))) as? [String: Any] ?? [:])
        }) ?? []
    }

    private static func piCredentials() -> [String: [String: Any]] {
        let url = home.appendingPathComponent(".pi/agent/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root.compactMapValues { $0 as? [String: Any] }
    }

    /// A GitHub OAuth token (`gho_…`/`ghu_…`) usable against api.github.com.
    static func githubToken() -> (token: String, via: String)? {
        func pick(_ d: [String: Any]) -> String? {
            for key in ["refresh", "access"] {
                if let t = d[key] as? String, t.hasPrefix("gh") { return t }
            }
            return nil
        }
        if let row = ompCredentials().first(where: { $0.0 == "github-copilot" }), let t = pick(row.1) {
            return (t, "omp login")
        }
        if let d = piCredentials()["github-copilot"], let t = pick(d) { return (t, "pi login") }
        return nil
    }

    /// Every distinct OpenRouter key on this Mac, labelled by the tool that holds it.
    static func openRouterKeys() -> [(key: String, via: String)] {
        var out: [(String, String)] = []
        func add(_ k: String?, _ via: String) {
            guard let k, !k.isEmpty, !out.contains(where: { $0.0 == k }) else { return }
            out.append((k, via))
        }
        add(ompCredentials().first(where: { $0.0 == "openrouter" })?.1["key"] as? String, "omp")
        add(piCredentials()["openrouter"]?["key"] as? String, "pi")
        add(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], "env")
        return out
    }
}

private func getJSON(_ url: String, headers: [String: String]) async -> (Int, [String: Any]?) {
    var req = URLRequest(url: URL(string: url)!)
    req.timeoutInterval = 20
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("TokenCounter/1.0", forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
    return ((resp as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

private func httpError(_ status: Int, reauth: String) -> String {
    switch status {
    case 0: "Network unavailable"
    case 401, 403: reauth
    case 429: "Rate limited — will retry"
    default: "HTTP \(status)"
    }
}

// MARK: - Claude

extension ClaudeLimits {
    var status: ProviderStatus {
        var s = ProviderStatus(kind: .claude, plan: plan?.capitalized, windows: windows,
                               fetchedAt: fetchedAt, error: error, via: "Claude Code login")
        if let e = extra {
            s.facts.append(Fact(label: "Extra usage",
                                value: e.enabled ? String(format: "%.2f / %.0f %@", e.used, e.limit, e.currency)
                                    : "Off" + (e.disabledReason.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? "")))
        }
        return s
    }
}

// MARK: - GitHub Copilot

/// Live Copilot quota from `api.github.com/copilot_internal/user` (what the Copilot editor extensions use).
enum CopilotClient {
    static func fetch() async -> ProviderStatus {
        var s = ProviderStatus(kind: .copilot)
        guard let (token, via) = StoredCredentials.githubToken() else {
            s.error = "No Copilot login found in omp or pi"
            return s
        }
        s.via = via
        let (status, json) = await getJSON("https://api.github.com/copilot_internal/user",
                                           headers: ["Authorization": "token \(token)"])
        guard status == 200, let json else {
            s.error = httpError(status, reauth: "GitHub token rejected — sign in to Copilot in omp again")
            return s
        }
        s.plan = (json["copilot_plan"] as? String)?.capitalized
        s.account = json["login"] as? String
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resets = (json["quota_reset_date_utc"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }

        let names = ["premium_interactions": "Premium requests", "chat": "Chat", "completions": "Code completions"]
        var unlimited: [String] = []
        for (id, raw) in (json["quota_snapshots"] as? [String: Any] ?? [:]).sorted(by: { $0.key > $1.key }) {
            guard let q = raw as? [String: Any] else { continue }
            let name = names[id] ?? id.replacingOccurrences(of: "_", with: " ").capitalized
            if q["unlimited"] as? Bool == true { unlimited.append(name); continue }
            guard let remainingPct = num(q["percent_remaining"]) else { continue }
            let total = num(q["entitlement"])
            let used = total.flatMap { t in num(q["remaining"]).map { t - $0 } } ?? num(q["credits_used"])
            var w = LimitWindow(id: "copilot|\(id)", label: "\(name) · monthly", percent: max(0, 100 - remainingPct), resetsAt: resets)
            w.used = used
            w.total = total
            if let used, let total {
                w.detail = "\(Int(used).formatted()) of \(Int(total).formatted()) used"
                    + (q["overage_permitted"] as? Bool == true ? " · overage allowed" : "")
            }
            s.windows.append(w)
        }
        if !unlimited.isEmpty { s.facts.append(Fact(label: "Unlimited", value: unlimited.joined(separator: ", "))) }
        s.fetchedAt = Date()
        return s
    }
}

// MARK: - OpenRouter

/// Account credits and per-key limits from OpenRouter's `/credits` and `/key` endpoints.
/// pi and omp may hold different keys, so each key's limits are shown separately.
enum OpenRouterClient {
    static func fetch() async -> ProviderStatus {
        var s = ProviderStatus(kind: .openRouter)
        let keys = StoredCredentials.openRouterKeys()
        guard !keys.isEmpty else {
            s.error = "No OpenRouter key found in omp or pi"
            return s
        }
        s.via = keys.map { "\($0.via) key" }.joined(separator: " + ")
        let multi = keys.count > 1
        var lastStatus = 0
        var seenCredits: [String] = []
        var freeTier = false
        for (key, via) in keys {
            let auth = ["Authorization": "Bearer \(key)"]
            async let creditsReq = getJSON("https://openrouter.ai/api/v1/credits", headers: auth)
            async let keyReq = getJSON("https://openrouter.ai/api/v1/key", headers: auth)
            let (cStatus, credits) = await creditsReq
            let (kStatus, keyInfo) = await keyReq
            lastStatus = max(cStatus, kStatus)
            let suffix = multi ? " · \(via) key" : ""

            // Credits belong to the account; two keys on the same account report the same numbers.
            if let d = credits?["data"] as? [String: Any], let total = num(d["total_credits"]), let used = num(d["total_usage"]) {
                let sig = String(format: "%.4f/%.4f", total, used)
                if !seenCredits.contains(sig) {
                    seenCredits.append(sig)
                    let acct = seenCredits.count > 1 ? " · \(via) account" : ""
                    let balance = total - used
                    s.facts.append(Fact(label: "Balance\(acct)", value: String(format: "$%.2f", balance), warning: balance < 1))
                    if total > 0 {
                        var w = LimitWindow(id: "openrouter|credits|\(via)", label: "Account credits used\(acct)", percent: used / total * 100, resetsAt: nil)
                        w.used = used
                        w.total = total
                        w.detail = String(format: "$%.2f of $%.2f · top up at openrouter.ai/credits", used, total)
                        s.windows.append(w)
                    }
                }
            }
            guard let d = keyInfo?["data"] as? [String: Any] else { continue }
            freeTier = freeTier || (d["is_free_tier"] as? Bool == true)
            if let limit = num(d["limit"]), limit > 0 {
                let used = num(d["usage"]) ?? 0
                var w = LimitWindow(id: "openrouter|key|\(via)", label: "Key spend limit\(suffix)", percent: used / limit * 100, resetsAt: nil)
                w.used = used
                w.total = limit
                w.detail = String(format: "$%.2f of $%.2f", used, limit) + ((d["limit_reset"] as? String).map { " · resets \($0)" } ?? "")
                s.windows.append(w)
            }
            if let free = d["free_model_daily_requests"] as? [String: Any], let limit = num(free["limit"]), limit > 0 {
                let used = num(free["used"]) ?? 0
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: "UTC")!
                let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
                var w = LimitWindow(id: "openrouter|free_daily|\(via)", label: "Free-model requests · daily\(suffix)",
                                    percent: used / limit * 100, resetsAt: midnight)
                w.used = used
                w.total = limit
                w.detail = "\(Int(used)) of \(Int(limit)) requests"
                s.windows.append(w)
            }
            let spend = [("usage_daily", "today"), ("usage_weekly", "week"), ("usage_monthly", "month")].compactMap { field, label in
                num(d[field]).map { String(format: "$%.2f %@", $0, label) }
            }
            if !spend.isEmpty { s.facts.append(Fact(label: "Spent\(suffix)", value: spend.joined(separator: " · "))) }
        }
        s.plan = freeTier ? "Free tier" : "Pay as you go"
        if s.isEmpty {
            s.error = httpError(lastStatus, reauth: "OpenRouter key rejected")
        } else {
            s.fetchedAt = Date()
        }
        return s
    }
}
