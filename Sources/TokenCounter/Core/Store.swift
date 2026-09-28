import Foundation

// MARK: - Query results

struct Totals: Sendable {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, reasoning = 0
    var cost = 0.0
    var requests = 0, sessions = 0, errors = 0
    var all: Int { input + output + cacheRead + cacheWrite }
    var cacheHitRate: Double {
        let denom = Double(input + cacheRead + cacheWrite)
        return denom > 0 ? Double(cacheRead) / denom : 0
    }
}

struct BucketPoint: Identifiable, Sendable {
    var id: String { "\(bucket.timeIntervalSince1970)|\(model)" }
    let bucket: Date
    let model: String
    let all: Int
    let inOut: Int
    let output: Int
    let cost: Double
}

struct ModelTotal: Identifiable, Sendable {
    var id: String { model }
    let model: String
    let sources: String
    let providers: String
    let totals: Totals
    let lastUsed: Date
}

struct HeatCell: Identifiable, Sendable {
    var id: String { "\(weekday)-\(hour)" }
    let weekday: Int // 0 = Sunday
    let hour: Int
    let tokens: Int
}

struct ProjectTotal: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let sessions: Int
    let tokens: Int
    let cost: Double
    let lastUsed: Date
    let sources: String
    var displayName: String?
    var name: String { path.isEmpty ? "(unknown)" : URL(fileURLWithPath: path).lastPathComponent }
    /// "parent/name", used when two projects share a folder name.
    var qualifiedName: String {
        let url = URL(fileURLWithPath: path)
        return path.isEmpty ? name : "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
    }
}

struct SessionSummary: Identifiable, Sendable {
    let id: String
    let source: Source
    let title: String?
    let project: String
    let start: Date
    let end: Date
    let requests: Int
    let tokens: Int
    let output: Int
    let cost: Double
    let models: [String]
    var projectName: String { project.isEmpty ? "—" : URL(fileURLWithPath: project).lastPathComponent }
    var displayTitle: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session" }
    var isActive: Bool { Date().timeIntervalSince(end) < 600 }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct NamedCount: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let count: Int
}

struct SourceTotal: Identifiable, Sendable {
    var id: String { source.rawValue }
    let source: Source
    let totals: Totals
}

struct LimitPoint: Identifiable, Sendable {
    var id: String { "\(key)|\(ts.timeIntervalSince1970)" }
    let ts: Date
    let key: String
    let label: String
    let percent: Double
}

struct Filter: Sendable, Equatable {
    var since: Date?
    var sources: Set<Source>
    var hourly: Bool
}

struct DashboardData: Sendable {
    var totals = Totals()
    var today = Totals()
    var claudeLast5h = Totals()
    var lastHour = Totals()
    var buckets: [BucketPoint] = []
    var models: [ModelTotal] = []
    var heat: [HeatCell] = []
    var projects: [ProjectTotal] = []
    var sessions: [SessionSummary] = []
    var tools: [NamedCount] = []
    var bySource: [SourceTotal] = []
    var limitHistory: [LimitPoint] = []
    /// All-time model rank; drives stable color assignment.
    var modelRank: [String] = []
    var firstRecord: Date?
}

// MARK: - Store

actor Store {
    static var defaultPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenCounter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.sqlite").path
    }

    private let db: SQLiteDB
    private let claude = ClaudeParser()
    private let pi = PiParser()
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init(path: String = Store.defaultPath) throws {
        db = try SQLiteDB(path: path)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS usage(
            key TEXT PRIMARY KEY, source TEXT NOT NULL, session_id TEXT NOT NULL, project TEXT,
            model TEXT NOT NULL, provider TEXT, ts REAL NOT NULL, hour INTEGER, weekday INTEGER,
            input INTEGER DEFAULT 0, output INTEGER DEFAULT 0, cache_read INTEGER DEFAULT 0,
            cache_write_5m INTEGER DEFAULT 0, cache_write_1h INTEGER DEFAULT 0, reasoning INTEGER DEFAULT 0,
            cost REAL DEFAULT 0, cost_estimated INTEGER DEFAULT 0, fast INTEGER DEFAULT 0,
            kind TEXT DEFAULT 'main', is_error INTEGER DEFAULT 0);
        CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage(ts);
        CREATE INDEX IF NOT EXISTS idx_usage_source_ts ON usage(source, ts);
        CREATE INDEX IF NOT EXISTS idx_usage_session ON usage(session_id);
        CREATE TABLE IF NOT EXISTS tool_calls(key TEXT PRIMARY KEY, ts REAL, source TEXT, session_id TEXT, tool TEXT);
        CREATE INDEX IF NOT EXISTS idx_tools_ts ON tool_calls(ts);
        CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, source TEXT, title TEXT, cwd TEXT);
        CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, size INTEGER, mtime REAL, offset INTEGER,
            session_id TEXT, cwd TEXT);
        CREATE TABLE IF NOT EXISTS limit_snapshots(ts REAL, provider TEXT, key TEXT, label TEXT,
            percent REAL, resets_at REAL, PRIMARY KEY(ts, provider, key));
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        """)
        // Columns added after the first release.
        try? db.exec("ALTER TABLE limit_snapshots ADD COLUMN used REAL")
        try? db.exec("ALTER TABLE limit_snapshots ADD COLUMN total REAL")
        try Store.repriceEstimates(db)
    }

    // MARK: Ingest

    private struct FileState { var size: Int; var mtime: Double; var offset: Int; var sessionId: String?; var cwd: String? }

    private var roots: [(Source, String)] {
        [(.claude, "\(home)/.claude/projects"),
         (.pi, "\(home)/.pi/agent/sessions"),
         (.omp, "\(home)/.omp/agent/sessions")]
    }

    func installedSources() -> [Source] {
        roots.filter { FileManager.default.fileExists(atPath: $0.1) }.map(\.0)
    }

    /// Reads any new bytes appended to session files. Returns the number of new usage rows.
    /// Rows are never deleted when a source file disappears: Claude Code prunes old
    /// transcripts, so this database becomes the only long-term history.
    @discardableResult
    func ingest() -> Int {
        var known: [String: FileState] = [:]
        if let rows = try? db.query("SELECT path,size,mtime,offset,session_id,cwd FROM files", map: {
            ($0.string(0), FileState(size: $0.int(1), mtime: $0.double(2), offset: $0.int(3),
                                     sessionId: $0.optString(4), cwd: $0.optString(5)))
        }) {
            for (p, s) in rows { known[p] = s }
        }

        var added = 0
        let fm = FileManager.default
        for (source, root) in roots {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                         includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      vals.isRegularFile == true else { continue }
                let size = vals.fileSize ?? 0
                let mtime = vals.contentModificationDate?.timeIntervalSince1970 ?? 0
                let path = url.path
                var state = known[path] ?? FileState(size: 0, mtime: 0, offset: 0)
                if state.size == size && state.mtime == mtime { continue }
                if size < state.offset { state.offset = 0 } // truncated or rewritten
                added += ingestFile(path: path, root: root, source: source, size: size, mtime: mtime, state: state)
            }
        }
        added += importClaudeStatsCache()
        return added
    }

    private func meta(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key=?", [key]) { $0.string(0) })?.first
    }

    private func setMeta(_ key: String, _ value: String) {
        try? db.run("INSERT OR REPLACE INTO meta VALUES(?,?)", [key, value])
    }

    /// Backfills days that only survive in Claude Code's `~/.claude/stats-cache.json`
    /// (per-day, per-model totals kept after transcripts are pruned). Those rows are marked
    /// `kind='archive'`: they carry input+output tokens only (no cache split, no sessions),
    /// and are skipped for any day that has real transcript data.
    private func importClaudeStatsCache() -> Int {
        let url = URL(fileURLWithPath: "\(home)/.claude/stats-cache.json")
        guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970,
              meta("stats_cache_mtime") != String(mtime),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return 0 }

        // `dailyModelTokens` is input+output per day. `modelUsage` has the matching per-model
        // totals incl. cache tokens, which are spread over the days in proportion, so per-model
        // totals are exact while the per-day split is an estimate.
        struct ModelTotals { var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0 }
        var totals: [String: ModelTotals] = [:]
        for (model, raw) in root["modelUsage"] as? [String: Any] ?? [:] {
            guard let u = raw as? [String: Any] else { continue }
            func v(_ k: String) -> Double { (u[k] as? NSNumber)?.doubleValue ?? 0 }
            totals[ModelNames.canonical(model), default: ModelTotals()].input += v("inputTokens")
            totals[ModelNames.canonical(model), default: ModelTotals()].output += v("outputTokens")
            totals[ModelNames.canonical(model), default: ModelTotals()].cacheRead += v("cacheReadInputTokens")
            totals[ModelNames.canonical(model), default: ModelTotals()].cacheWrite += v("cacheCreationInputTokens")
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = .current
        let liveDays = Set((try? db.query("""
            SELECT DISTINCT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') FROM usage WHERE source='claude' AND kind!='archive'
            """) { $0.string(0) }) ?? [])

        var rows: [UsageRow] = []
        for day in root["dailyModelTokens"] as? [[String: Any]] ?? [] {
            guard let dateStr = day["date"] as? String, !liveDays.contains(dateStr),
                  let date = df.date(from: dateStr) else { continue }
            for (rawModel, v) in day["tokensByModel"] as? [String: Any] ?? [:] {
                let tokens = (v as? NSNumber)?.intValue ?? 0
                guard tokens > 0 else { continue }
                let model = ModelNames.canonical(rawModel)
                var r = UsageRow(key: "ccarchive|\(dateStr)|\(model)", source: .claude, sessionId: "archive-\(dateStr)",
                                 project: "", model: model, provider: "anthropic", ts: date.addingTimeInterval(12 * 3600).timeIntervalSince1970)
                let t = totals[model] ?? ModelTotals()
                let io = t.input + t.output
                let share = io > 0 ? Double(tokens) / io : 0
                r.output = Int((Double(tokens) * (io > 0 ? t.output / io : 0.5)).rounded())
                r.input = tokens - r.output
                r.cacheRead = Int((t.cacheRead * share).rounded())
                r.cacheWrite5m = Int((t.cacheWrite * share).rounded())
                r.kind = "archive"
                rows.append(r)
            }
        }
        do {
            try db.transaction {
                try db.run("DELETE FROM usage WHERE kind='archive'")
                try write(ParseOutput(usage: rows))
            }
            setMeta("stats_cache_mtime", String(mtime))
        } catch {
            NSLog("TokenCounter: stats-cache import failed: \(error)")
        }
        return rows.count
    }

    private func ingestFile(path: String, root: String, source: Source, size: Int, mtime: Double, state: FileState) -> Int {
        guard let fh = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: UInt64(state.offset)) } catch { return 0 }
        guard let data = try? fh.readToEnd(), !data.isEmpty else {
            try? db.run("INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?)", [path, size, mtime, state.offset, state.sessionId, state.cwd])
            return 0
        }

        var ctx = FileContext(path: path, source: source, sessionId: state.sessionId, cwd: state.cwd)
        if source != .claude {
            // omp/pi sub-agent transcripts live in `<project>/<parent-session-file-stem>/<agent>.jsonl`.
            let rel = path.dropFirst(root.count + 1).split(separator: "/")
            if rel.count >= 3 { ctx.parentSessionId = pi.idFromStem(String(rel[rel.count - 2])) }
        }

        let (out, consumed) = source == .claude ? claude.parse(data, ctx: ctx) : pi.parse(data, ctx: ctx)
        let sessionId = out.fileSessionId ?? state.sessionId
        let cwd = out.fileCwd ?? state.cwd
        do {
            try db.transaction {
                try write(out)
                try db.run("INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?)",
                           [path, size, mtime, state.offset + consumed, sessionId, cwd])
            }
        } catch {
            NSLog("TokenCounter: ingest failed for \(path): \(error)")
            return 0
        }
        return out.usage.count
    }

    private func write(_ out: ParseOutput) throws {
        let cal = Calendar.current
        let up = try db.prepare("""
        INSERT INTO usage(key,source,session_id,project,model,provider,ts,hour,weekday,input,output,cache_read,
            cache_write_5m,cache_write_1h,reasoning,cost,cost_estimated,fast,kind,is_error)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(key) DO UPDATE SET
            input=max(input,excluded.input), output=max(output,excluded.output),
            cache_read=max(cache_read,excluded.cache_read),
            cache_write_5m=max(cache_write_5m,excluded.cache_write_5m),
            cache_write_1h=max(cache_write_1h,excluded.cache_write_1h),
            reasoning=max(reasoning,excluded.reasoning), cost=max(cost,excluded.cost)
        """)
        for r in out.usage {
            let date = Date(timeIntervalSince1970: r.ts)
            let comps = cal.dateComponents([.hour, .weekday], from: date)
            let estimated = r.reportedCost == nil
            let cost = r.reportedCost ?? estimate(r)
            up.bind([r.key, r.source.rawValue, r.sessionId, r.project, r.model, r.provider, r.ts,
                     comps.hour ?? 0, (comps.weekday ?? 1) - 1, r.input, r.output, r.cacheRead,
                     r.cacheWrite5m, r.cacheWrite1h, r.reasoning, cost, estimated, r.fast, r.kind, r.isError])
            up.step()
        }
        let tool = try db.prepare("INSERT OR IGNORE INTO tool_calls VALUES(?,?,?,?,?)")
        for t in out.tools {
            tool.bind([t.key, t.ts, t.source.rawValue, t.sessionId, t.tool])
            tool.step()
        }
        let sess = try db.prepare("""
        INSERT INTO sessions(id,source,title,cwd) VALUES(?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET title=coalesce(excluded.title,title), cwd=coalesce(excluded.cwd,cwd)
        """)
        for s in out.sessions {
            sess.bind([s.id, s.source.rawValue, s.title, s.cwd])
            sess.step()
        }
    }

    private func estimate(_ r: UsageRow) -> Double {
        guard let rate = Pricing.rate(for: r.model) else { return 0 }
        let base = Double(r.input) * rate.input + Double(r.output) * rate.output
            + Double(r.cacheRead) * rate.cacheRead + Double(r.cacheWrite5m) * rate.write5m
            + Double(r.cacheWrite1h) * rate.write1h
        return base / 1_000_000 * (r.fast ? Pricing.fastMultiplier : 1)
    }

    /// Re-applies the price table to every estimated row, so price edits apply retroactively.
    private static func repriceEstimates(_ db: SQLiteDB) throws {
        let models = try db.query("SELECT DISTINCT model FROM usage WHERE cost_estimated=1") { $0.string(0) }
        try db.transaction {
            for m in models {
                guard let r = Pricing.rate(for: m) else {
                    try db.run("UPDATE usage SET cost=0 WHERE cost_estimated=1 AND model=?", [m]); continue
                }
                try db.run("""
                UPDATE usage SET cost=(input*?+output*?+cache_read*?+cache_write_5m*?+cache_write_1h*?)/1e6
                    * (CASE WHEN fast=1 THEN ? ELSE 1 END)
                WHERE cost_estimated=1 AND model=?
                """, [r.input, r.output, r.cacheRead, r.write5m, r.write1h, Pricing.fastMultiplier, m])
            }
        }
    }

    // MARK: Limits history

    /// Saves quota readings. A row is written when a value changes, or every 15 minutes
    /// otherwise, so the history stays compact while the app runs all day.
    func recordLimits(provider: String, _ windows: [LimitWindow]) {
        let now = Date().timeIntervalSince1970
        try? db.transaction {
            for w in windows {
                let last = try db.query("""
                    SELECT ts, percent FROM limit_snapshots WHERE provider=? AND key=? ORDER BY ts DESC LIMIT 1
                    """, [provider, w.id]) { ($0.double(0), $0.double(1)) }.first
                if let last, abs(last.1 - w.percent) < 0.05, now - last.0 < 900 { continue }
                try db.run("INSERT OR REPLACE INTO limit_snapshots(ts,provider,key,label,percent,resets_at,used,total) VALUES(?,?,?,?,?,?,?,?)",
                           [now, provider, w.id, w.label, w.percent, w.resetsAt?.timeIntervalSince1970, w.used, w.total])
            }
        }
    }

    /// The most recent recorded snapshot (within `maxAge`), used to show limits right after launch.
    func latestLimits(provider: String, maxAge: TimeInterval = 6 * 3600) -> (Date, [LimitWindow])? {
        let since = Date().addingTimeInterval(-maxAge).timeIntervalSince1970
        guard let ts = (try? db.query("SELECT max(ts) FROM limit_snapshots WHERE provider=? AND ts >= ?", [provider, since]) { $0.optDouble(0) })?.first ?? nil
        else { return nil }
        let windows = (try? db.query("""
            SELECT key, label, percent, resets_at, used, total FROM limit_snapshots l
            WHERE provider=? AND ts=(SELECT max(ts) FROM limit_snapshots WHERE provider=l.provider AND key=l.key) AND ts >= ?
            """, [provider, since]) { (s: Statement) -> LimitWindow in
            var w = LimitWindow(id: s.string(0), label: s.string(1), percent: s.double(2),
                                resetsAt: s.optDouble(3).map { Date(timeIntervalSince1970: $0) })
            w.used = s.optDouble(4)
            w.total = s.optDouble(5)
            return w
        }) ?? []
        // Keep the gauge order stable: session, weekly, then the rest.
        let order = ["five_hour", "seven_day"]
        let sorted = windows.sorted { (a: LimitWindow, b: LimitWindow) -> Bool in
            let ia = order.firstIndex(of: a.id) ?? 9, ib = order.firstIndex(of: b.id) ?? 9
            return ia != ib ? ia < ib : a.id < b.id
        }
        return (Date(timeIntervalSince1970: ts), sorted)
    }

    // MARK: Queries

    private static let totalExpr = "(input+output+cache_read+cache_write_5m+cache_write_1h)"
    private static let totalsCols = """
    coalesce(sum(input),0), coalesce(sum(output),0), coalesce(sum(cache_read),0),
    coalesce(sum(cache_write_5m+cache_write_1h),0), coalesce(sum(reasoning),0), coalesce(sum(cost),0),
    coalesce(sum(CASE WHEN is_error=0 AND kind!='archive' THEN 1 ELSE 0 END),0),
    count(DISTINCT CASE WHEN kind!='archive' THEN session_id END), coalesce(sum(is_error),0)
    """

    private func readTotals(_ s: Statement, from i: Int32) -> Totals {
        Totals(input: s.int(i), output: s.int(i + 1), cacheRead: s.int(i + 2), cacheWrite: s.int(i + 3),
               reasoning: s.int(i + 4), cost: s.double(i + 5), requests: s.int(i + 6),
               sessions: s.int(i + 7), errors: s.int(i + 8))
    }

    /// `live` drops archive rows, which have no real time of day, project or session.
    private func whereClause(_ f: Filter, since: Date? = nil, table: String = "", live: Bool = false) -> (String, [Any?]) {
        var parts: [String] = live ? ["\(table)kind != 'archive'"] : []
        var params: [Any?] = []
        if let s = since ?? f.since { parts.append("\(table)ts >= ?"); params.append(s.timeIntervalSince1970) }
        let srcs = f.sources.map(\.rawValue).sorted()
        if srcs.count < Source.allCases.count {
            parts.append("\(table)source IN (\(srcs.map { _ in "?" }.joined(separator: ",")))")
            params.append(contentsOf: srcs as [Any?])
            if srcs.isEmpty { parts.append("0") }
        }
        return (parts.isEmpty ? "" : "WHERE " + parts.joined(separator: " AND "), params)
    }

    private func totals(_ f: Filter, since: Date? = nil, extra: String = "") -> Totals {
        var (w, p) = whereClause(f, since: since)
        if !extra.isEmpty { w += (w.isEmpty ? "WHERE " : " AND ") + extra }
        return (try? db.query("SELECT \(Self.totalsCols) FROM usage \(w)", p) { readTotals($0, from: 0) })?.first ?? Totals()
    }

    func dashboard(_ f: Filter) -> DashboardData {
        var d = DashboardData()
        let (w, p) = whereClause(f)
        let total = Self.totalExpr
        let now = Date()

        d.totals = totals(f)
        d.today = totals(f, since: Calendar.current.startOfDay(for: now))
        d.lastHour = totals(f, since: now.addingTimeInterval(-3600))
        d.claudeLast5h = totals(Filter(since: nil, sources: [.claude], hourly: false), since: now.addingTimeInterval(-5 * 3600))

        let bucketExpr = f.hourly
            ? "strftime('%Y-%m-%d %H:00:00', ts, 'unixepoch', 'localtime')"
            : "strftime('%Y-%m-%d 00:00:00', ts, 'unixepoch', 'localtime')"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = .current
        d.buckets = (try? db.query("""
            SELECT \(bucketExpr) b, model, sum(\(total)), sum(input+output), sum(output), sum(cost)
            FROM usage \(w) GROUP BY b, model ORDER BY b
            """, p) { s in
            BucketPoint(bucket: df.date(from: s.string(0)) ?? now, model: s.string(1), all: s.int(2),
                        inOut: s.int(3), output: s.int(4), cost: s.double(5))
        }) ?? []

        d.models = (try? db.query("""
            SELECT model, group_concat(DISTINCT source), group_concat(DISTINCT provider), \(Self.totalsCols), max(ts)
            FROM usage \(w) GROUP BY model ORDER BY sum(\(total)) DESC
            """, p) { s in
            ModelTotal(model: s.string(0), sources: s.string(1), providers: s.string(2),
                       totals: readTotals(s, from: 3), lastUsed: Date(timeIntervalSince1970: s.double(12)))
        }) ?? []

        let (wl, pl) = whereClause(f, live: true)
        d.heat = (try? db.query("SELECT weekday, hour, sum(\(total)) FROM usage \(wl) GROUP BY weekday, hour", pl) {
            HeatCell(weekday: $0.int(0), hour: $0.int(1), tokens: $0.int(2))
        }) ?? []

        d.projects = Store.disambiguate((try? db.query("""
            SELECT project, count(DISTINCT session_id), sum(\(total)), sum(cost), max(ts), group_concat(DISTINCT source)
            FROM usage \(wl) GROUP BY project ORDER BY sum(\(total)) DESC
            """, pl) { s in
            ProjectTotal(path: s.string(0), sessions: s.int(1), tokens: s.int(2), cost: s.double(3),
                         lastUsed: Date(timeIntervalSince1970: s.double(4)), sources: s.string(5))
        }) ?? [])

        let (wu, pu) = whereClause(f, table: "u.", live: true)
        d.sessions = (try? db.query("""
            SELECT u.session_id, max(u.source), s.title,
                   coalesce(s.cwd, (SELECT project FROM usage f WHERE f.session_id = u.session_id ORDER BY f.ts LIMIT 1)),
                   min(u.ts), max(u.ts),
                   sum(CASE WHEN u.is_error=0 THEN 1 ELSE 0 END), sum(\(total)), sum(u.output), sum(u.cost),
                   group_concat(DISTINCT u.model)
            FROM usage u LEFT JOIN sessions s ON s.id = u.session_id \(wu)
            GROUP BY u.session_id ORDER BY max(u.ts) DESC LIMIT 1000
            """, pu) { s in
            SessionSummary(id: s.string(0), source: Source(rawValue: s.string(1)) ?? .claude, title: s.optString(2),
                           project: s.string(3), start: Date(timeIntervalSince1970: s.double(4)),
                           end: Date(timeIntervalSince1970: s.double(5)), requests: s.int(6), tokens: s.int(7),
                           output: s.int(8), cost: s.double(9),
                           models: s.string(10).split(separator: ",").map(String.init))
        }) ?? []

        let (wt, pt) = whereClause(f)
        d.tools = (try? db.query("SELECT tool, count(*) FROM tool_calls \(wt) GROUP BY tool ORDER BY 2 DESC LIMIT 20", pt) {
            NamedCount(name: $0.string(0), count: $0.int(1))
        }) ?? []

        d.bySource = (try? db.query("SELECT source, \(Self.totalsCols) FROM usage \(w) GROUP BY source ORDER BY sum(\(total)) DESC", p) { s in
            SourceTotal(source: Source(rawValue: s.string(0)) ?? .claude, totals: readTotals(s, from: 1))
        }) ?? []

        let histSince = max(f.since?.timeIntervalSince1970 ?? 0, now.addingTimeInterval(-14 * 86400).timeIntervalSince1970)
        d.limitHistory = (try? db.query("""
            SELECT ts, key, label, percent FROM limit_snapshots WHERE ts >= ? ORDER BY ts
            """, [histSince]) { s in
            LimitPoint(ts: Date(timeIntervalSince1970: s.double(0)), key: s.string(1), label: s.string(2), percent: s.double(3))
        }) ?? []

        d.modelRank = (try? db.query("SELECT model FROM usage GROUP BY model ORDER BY sum(\(total)) DESC") { $0.string(0) }) ?? []
        if let first = (try? db.query("SELECT min(ts) FROM usage") { $0.optDouble(0) })?.first, let first {
            d.firstRecord = Date(timeIntervalSince1970: first)
        }
        return d
    }

    private static func disambiguate(_ projects: [ProjectTotal]) -> [ProjectTotal] {
        let counts = Dictionary(grouping: projects, by: \.name).mapValues(\.count)
        return projects.map { p in
            var q = p
            if (counts[p.name] ?? 0) > 1 { q.displayName = p.qualifiedName }
            return q
        }
    }

    // MARK: Help page / detail / export

    func stats(path: String) -> DatabaseStats {
        func count(_ sql: String) -> Int { (try? db.query(sql) { $0.int(0) })?.first ?? 0 }
        var st = DatabaseStats(path: path)
        st.bytes = ["", "-wal"].compactMap { (try? FileManager.default.attributesOfItem(atPath: path + $0))?[.size] as? Int }.reduce(0, +)
        st.usageRows = count("SELECT count(*) FROM usage WHERE kind!='archive'")
        st.archiveDays = count("SELECT count(DISTINCT session_id) FROM usage WHERE kind='archive'")
        st.toolCalls = count("SELECT count(*) FROM tool_calls")
        st.sessions = count("SELECT count(DISTINCT session_id) FROM usage WHERE kind!='archive'")
        st.snapshots = count("SELECT count(*) FROM limit_snapshots")
        st.trackedFiles = count("SELECT count(*) FROM files")
        let fm = FileManager.default
        st.missingFiles = ((try? db.query("SELECT path FROM files") { $0.string(0) }) ?? []).filter { !fm.fileExists(atPath: $0) }.count
        if let first = (try? db.query("SELECT min(ts) FROM usage") { $0.optDouble(0) })?.first, let first {
            st.oldest = Date(timeIntervalSince1970: first)
        }
        return st
    }

    func sessionDetail(_ id: String) -> SessionDetail {
        var d = SessionDetail()
        d.models = (try? db.query("""
            SELECT model, \(Self.totalsCols), max(ts) FROM usage WHERE session_id=? GROUP BY model ORDER BY sum(\(Self.totalExpr)) DESC
            """, [id]) { s in
            ModelTotal(model: s.string(0), sources: "", providers: "", totals: readTotals(s, from: 1),
                       lastUsed: Date(timeIntervalSince1970: s.double(10)))
        }) ?? []
        d.tools = (try? db.query("SELECT tool, count(*) FROM tool_calls WHERE session_id=? GROUP BY tool ORDER BY 2 DESC", [id]) {
            NamedCount(name: $0.string(0), count: $0.int(1))
        }) ?? []
        d.kinds = (try? db.query("SELECT kind, count(*) FROM usage WHERE session_id=? GROUP BY kind", [id]) {
            NamedCount(name: $0.string(0), count: $0.int(1))
        }) ?? []
        d.cwd = (try? db.query("""
            SELECT coalesce((SELECT cwd FROM sessions WHERE id=?1), (SELECT project FROM usage WHERE session_id=?1 ORDER BY ts LIMIT 1))
            """, [id]) {
            $0.optString(0)
        })?.first ?? nil
        return d
    }

    /// Writes every usage row (no message content) as CSV.
    func exportCSV(to url: URL) throws -> Int {
        let iso = ISO8601DateFormatter()
        var out = "timestamp,agent,session_id,session_title,project,provider,model,kind,input,output,cache_read,cache_write_5m,cache_write_1h,reasoning,cost_usd,cost_estimated,is_error\n"
        func esc(_ v: String) -> String {
            v.contains(where: { ",\"\n".contains($0) }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
        }
        let rows = try db.query("""
            SELECT u.ts, u.source, u.session_id, coalesce(s.title,''), u.project, u.provider, u.model, u.kind, u.input, u.output,
                   u.cache_read, u.cache_write_5m, u.cache_write_1h, u.reasoning, u.cost, u.cost_estimated, u.is_error
            FROM usage u LEFT JOIN sessions s ON s.id=u.session_id ORDER BY u.ts
            """) { s -> String in
            [iso.string(from: Date(timeIntervalSince1970: s.double(0))), s.string(1), s.string(2), esc(s.string(3)), esc(s.string(4)),
             s.string(5), s.string(6), s.string(7), String(s.int(8)), String(s.int(9)), String(s.int(10)), String(s.int(11)),
             String(s.int(12)), String(s.int(13)), String(format: "%.6f", s.double(14)), String(s.int(15)), String(s.int(16))]
                .joined(separator: ",")
        }
        out += rows.joined(separator: "\n") + "\n"
        try out.write(to: url, atomically: true, encoding: .utf8)
        return rows.count
    }
}

struct DatabaseStats: Sendable {
    var path: String
    var bytes = 0
    var usageRows = 0
    var archiveDays = 0
    var toolCalls = 0
    var sessions = 0
    var snapshots = 0
    var trackedFiles = 0
    var missingFiles = 0
    var oldest: Date?
}

struct SessionDetail: Sendable {
    var models: [ModelTotal] = []
    var tools: [NamedCount] = []
    var kinds: [NamedCount] = []
    var cwd: String?
}
