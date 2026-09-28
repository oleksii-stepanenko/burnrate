import Foundation

struct LimitWindow: Identifiable, Sendable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?
    var detail: String?
    /// When the number was observed; set for data read from another tool's cache.
    var recordedAt: Date?
    /// Absolute amounts behind the percentage (requests, dollars…), when the provider reports them.
    var used: Double?
    var total: Double?

    var isStale: Bool { recordedAt.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? false }
}

struct ExtraUsage: Sendable {
    let enabled: Bool
    let used: Double
    let limit: Double
    let currency: String
    let disabledReason: String?
}

struct ClaudeLimits: Sendable {
    var windows: [LimitWindow] = []
    var extra: ExtraUsage?
    var plan: String?
    var tier: String?
    var fetchedAt: Date?
    var error: String?

    var session: LimitWindow? { windows.first { $0.id == "five_hour" } }
    var weekly: LimitWindow? { windows.first { $0.id == "seven_day" } }
}

/// Reads the subscription usage that Claude Code's `/usage` screen shows.
///
/// The OAuth token is read from the Keychain item Claude Code maintains (falling back to
/// `~/.claude/.credentials.json`). The token is never refreshed here: refreshing rotates the
/// refresh token and would sign Claude Code out. If it has expired, running Claude Code renews it.
enum ClaudeLimitsClient {
    private struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let plan: String?
        let tier: String?
    }

    private static func readCredentials() -> Credentials? {
        func decode(_ data: Data) -> Credentials? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let o = root["claudeAiOauth"] as? [String: Any],
                  let token = o["accessToken"] as? String else { return nil }
            let exp = (o["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return Credentials(accessToken: token, expiresAt: exp,
                               plan: o["subscriptionType"] as? String, tier: o["rateLimitTier"] as? String)
        }
        // `security` avoids re-prompting for Keychain access every time an ad-hoc signed build changes.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var keychain: Credentials?
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { keychain = decode(data) }
        }
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        let file = (try? Data(contentsOf: fileURL)).flatMap(decode)
        // Prefer whichever token expires last; the other one is stale.
        return [keychain, file].compactMap { $0 }.max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
    }

    private static let known: [(key: String, label: String)] = [
        ("five_hour", "Current session · 5h"),
        ("seven_day", "Weekly · all models"),
        ("seven_day_opus", "Weekly · Opus"),
        ("seven_day_sonnet", "Weekly · Sonnet"),
        ("seven_day_oauth_apps", "Weekly · OAuth apps"),
        ("seven_day_cowork", "Weekly · Cowork"),
    ]

    static func fetch() async -> ClaudeLimits {
        var result = ClaudeLimits()
        guard let creds = readCredentials() else {
            result.error = "No Claude Code login found"
            return result
        }
        result.plan = creds.plan
        result.tier = creds.tier
        if let exp = creds.expiresAt, exp < Date() {
            result.error = "Token expired — open Claude Code to refresh it"
            return result
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                result.error = status == 429 ? "Rate limited — will retry" : "Usage API returned HTTP \(status)"
                return result
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result.error = "Unexpected response"
                return result
            }
            result.windows = parseWindows(root)
            if let e = root["extra_usage"] as? [String: Any] {
                result.extra = ExtraUsage(enabled: e["is_enabled"] as? Bool ?? false,
                                          used: (e["used_credits"] as? NSNumber)?.doubleValue ?? 0,
                                          limit: (e["monthly_limit"] as? NSNumber)?.doubleValue ?? 0,
                                          currency: e["currency"] as? String ?? "USD",
                                          disabledReason: e["disabled_reason"] as? String)
            }
            result.fetchedAt = Date()
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    /// oh-my-claudecode's HUD polls the same endpoint (sharing its rate limit) and caches the
    /// result on disk. When we are rate-limited, a fresh reading from there is as good as ours.
    static func omcHudCache(maxAge: TimeInterval = 15 * 60) -> (Date, [LimitWindow])? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins/oh-my-claudecode/.usage-cache-anthropic.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let ms = (root["lastSuccessAt"] as? NSNumber ?? root["timestamp"] as? NSNumber)?.doubleValue
        else { return nil }
        let at = Date(timeIntervalSince1970: ms / 1000)
        guard Date().timeIntervalSince(at) < maxAge else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [LimitWindow] = []
        for (prefix, id, label) in [("fiveHour", "five_hour", "Current session · 5h"), ("weekly", "seven_day", "Weekly · all models"),
                                    ("opusWeekly", "seven_day_opus", "Weekly · Opus"), ("sonnetWeekly", "seven_day_sonnet", "Weekly · Sonnet")] {
            guard let pct = (d["\(prefix)Percent"] as? NSNumber)?.doubleValue else { continue }
            let resets = (d["\(prefix)ResetsAt"] as? String).flatMap { iso.date(from: $0) }
            out.append(LimitWindow(id: id, label: label, percent: pct, resetsAt: resets))
        }
        return out.isEmpty ? nil : (at, out)
    }

    static func parseWindows(_ root: [String: Any]) -> [LimitWindow] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ v: Any?) -> Date? {
            guard let s = v as? String else { return nil }
            return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        var out: [LimitWindow] = []
        for (key, label) in known {
            guard let w = root[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
            out.append(LimitWindow(id: key, label: label, percent: u, resetsAt: date(w["resets_at"])))
        }
        // The generic `limits` list may carry windows that have no named field yet.
        let covered: [String: String] = ["session": "five_hour", "weekly_all": "seven_day"]
        for l in root["limits"] as? [[String: Any]] ?? [] {
            guard let kind = l["kind"] as? String, let pct = (l["percent"] as? NSNumber)?.doubleValue else { continue }
            let id = covered[kind] ?? kind
            let resets = date(l["resets_at"])
            // Skip entries that duplicate a named window (same percent and reset time).
            let duplicate = out.contains { w in
                w.id == id || (abs(w.percent - pct) < 0.5 && abs((w.resetsAt ?? .distantPast).timeIntervalSince(resets ?? .distantPast)) < 60)
            }
            if duplicate { continue }
            let label = kind.replacingOccurrences(of: "_", with: " ").capitalized
            out.append(LimitWindow(id: id, label: label, percent: pct, resetsAt: resets))
        }
        return out
    }
}

/// GitHub Copilot premium-request quota snapshots that omp records in `~/.omp/agent/agent.db`.
enum OmpQuotaReader {
    static func read() -> [LimitWindow] {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omp/agent/agent.db").path
        guard FileManager.default.fileExists(atPath: path), let db = try? SQLiteDB(path: path, readOnly: true) else { return [] }
        let rows = (try? db.query("""
            SELECT provider, limit_id, label, window_label, used_fraction, resets_at, email, max(recorded_at)
            FROM usage_history WHERE used_fraction IS NOT NULL GROUP BY provider, account_key, limit_id
            """) { s -> LimitWindow in
            let provider = s.string(0)
            let resets = s.optDouble(5).map { Date(timeIntervalSince1970: $0 / 1000) }
            let recorded = Date(timeIntervalSince1970: s.double(7) / 1000)
            let window = s.optString(3).map { " · \($0)" } ?? ""
            let who = s.optString(6).map { " (\($0))" } ?? ""
            return LimitWindow(id: "\(provider)|\(s.string(1))",
                               label: "\(provider.replacingOccurrences(of: "-", with: " ").capitalized.replacingOccurrences(of: "Github", with: "GitHub")) · \(s.string(2))\(window)",
                               percent: s.double(4) * 100, resetsAt: resets,
                               detail: "via omp\(who), as of \(recorded.formatted(.relative(presentation: .named)))",
                               recordedAt: recorded)
        }) ?? []
        // Drop windows that already reset since omp last recorded them.
        return rows.filter { ($0.resetsAt ?? .distantFuture) > Date() }
    }
}
