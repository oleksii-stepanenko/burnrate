import Foundation

/// What a parser extracted from a chunk of a session file.
struct ParseOutput {
    var usage: [UsageRow] = []
    var tools: [ToolCallRow] = []
    var sessions: [SessionMeta] = []
    /// Session id / cwd discovered in this chunk (pi/omp write them once at the top).
    var fileSessionId: String?
    var fileCwd: String?
}

/// Context carried between incremental reads of the same file.
struct FileContext {
    var path: String
    var source: Source
    var sessionId: String?
    var cwd: String?
    /// Set for sub-agent transcripts: usage is attributed to the parent session.
    var parentSessionId: String?
}

/// A line borrowed from the file buffer; only valid inside the `forEachLine` callback.
struct Line {
    let ptr: UnsafeRawPointer
    let count: Int

    func contains(_ needle: [UInt8], within limit: Int? = nil) -> Bool {
        let n = min(count, limit ?? count)
        return needle.withUnsafeBytes { memmem(ptr, n, $0.baseAddress, needle.count) } != nil
    }

    var data: Data { Data(bytes: ptr, count: count) }
}

enum LineScanner {
    /// Calls `body` for each complete line in `data`. Returns the byte count consumed
    /// (up to and including the last newline); a trailing partial line is left for later.
    static func forEachLine(_ data: Data, _ body: (Line) -> Void) -> Int {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var start = 0
            while start < raw.count {
                guard let nl = memchr(base + start, 0x0A, raw.count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(nl))
                if end > start { body(Line(ptr: base + start, count: end - start)) }
                start = end + 1
            }
            return start
        }
    }
}

private let kUsage = Array("\"usage\"".utf8)
private let kAITitle = Array("\"type\":\"ai-title\"".utf8)
private let kSession = Array("\"type\":\"session\"".utf8)
private let kTitle = Array("\"type\":\"title\"".utf8)
private let kSessionInfo = Array("\"type\":\"session_info\"".utf8)
private let headerWindow = 48

private func json(_ line: Line) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: line.data)) as? [String: Any]
}

private func int(_ v: Any?) -> Int {
    switch v {
    case let n as NSNumber: return n.intValue
    case let s as String: return Int(s) ?? 0
    default: return 0
    }
}

private func double(_ v: Any?) -> Double? {
    (v as? NSNumber)?.doubleValue
}

final class TimestampParser {
    private let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plain = ISO8601DateFormatter()

    func parse(_ v: Any?) -> Double? {
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d > 1e11 ? d / 1000 : d // ms vs s
        }
        guard let s = v as? String else { return nil }
        return (frac.date(from: s) ?? plain.date(from: s))?.timeIntervalSince1970
    }
}

// MARK: - Claude Code

/// Parses `~/.claude/projects/<project>/<session>.jsonl` (and `<session>/subagents/*.jsonl`).
/// Each assistant API response is written once per content block with the same
/// `message.id`/`requestId`; the store merges those copies by taking the max of each field.
struct ClaudeParser {
    let ts = TimestampParser()

    func parse(_ data: Data, ctx: FileContext) -> (ParseOutput, Int) {
        var out = ParseOutput()
        let isSubagent = ctx.path.contains("/subagents/")
        let consumed = LineScanner.forEachLine(data) { line in
            if line.contains(kAITitle, within: headerWindow) {
                if let d = json(line), let sid = d["sessionId"] as? String, let t = d["aiTitle"] as? String {
                    out.sessions.append(SessionMeta(id: sid, source: .claude, title: t, cwd: nil))
                }
                return
            }
            guard line.contains(kUsage), let d = json(line),
                  d["type"] as? String == "assistant",
                  let msg = d["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let rawModel = msg["model"] as? String, rawModel != "<synthetic>"
            else { return }

            let sessionId = (d["sessionId"] as? String) ?? ctx.sessionId ?? URL(fileURLWithPath: ctx.path).deletingPathExtension().lastPathComponent
            let cwd = (d["cwd"] as? String) ?? ctx.cwd ?? ""
            if out.fileCwd == nil, !cwd.isEmpty { out.fileCwd = cwd; out.fileSessionId = sessionId }
            let time = ts.parse(d["timestamp"]) ?? Date().timeIntervalSince1970
            let msgId = (msg["id"] as? String) ?? (d["uuid"] as? String) ?? UUID().uuidString
            let baseKey = "cc|\(msgId)|\((d["requestId"] as? String) ?? "")"

            var row = UsageRow(key: baseKey, source: .claude, sessionId: sessionId, project: cwd,
                               model: ModelNames.canonical(rawModel), provider: "anthropic", ts: time)
            row.input = int(usage["input_tokens"])
            row.output = int(usage["output_tokens"])
            row.cacheRead = int(usage["cache_read_input_tokens"])
            fillCacheWrites(&row, usage)
            row.reasoning = int((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"])
            row.fast = (usage["speed"] as? String) == "fast"
            row.kind = isSubagent || (d["isSidechain"] as? Bool == true) ? "subagent" : "main"
            row.isError = d["isApiErrorMessage"] as? Bool == true
            out.usage.append(row)

            // Advisor sub-calls run on another model and are NOT included in the
            // top-level usage totals, so they become rows of their own.
            if let iterations = usage["iterations"] as? [[String: Any]] {
                for (i, it) in iterations.enumerated() where (it["type"] as? String) == "advisor_message" {
                    let m = (it["model"] as? String) ?? (d["advisorModel"] as? String) ?? rawModel
                    var adv = UsageRow(key: "\(baseKey)|adv\(i)", source: .claude, sessionId: sessionId, project: cwd,
                                       model: ModelNames.canonical(m), provider: "anthropic", ts: time)
                    adv.input = int(it["input_tokens"])
                    adv.output = int(it["output_tokens"])
                    adv.cacheRead = int(it["cache_read_input_tokens"])
                    fillCacheWrites(&adv, it)
                    adv.kind = "advisor"
                    out.usage.append(adv)
                }
            }

            if let content = msg["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "tool_use" {
                    guard let name = block["name"] as? String else { continue }
                    let id = (block["id"] as? String) ?? "\(msgId)-\(name)"
                    out.tools.append(ToolCallRow(key: "cc|\(id)", ts: time, source: .claude, sessionId: sessionId, tool: name))
                }
            }
        }
        return (out, consumed)
    }

    private func fillCacheWrites(_ row: inout UsageRow, _ usage: [String: Any]) {
        let total = int(usage["cache_creation_input_tokens"])
        if let cc = usage["cache_creation"] as? [String: Any] {
            row.cacheWrite1h = int(cc["ephemeral_1h_input_tokens"])
            row.cacheWrite5m = int(cc["ephemeral_5m_input_tokens"])
            // Anything unaccounted for is priced as a 5-minute write.
            row.cacheWrite5m += max(0, total - row.cacheWrite1h - row.cacheWrite5m)
        } else {
            row.cacheWrite5m = total
        }
    }
}

// MARK: - pi / omp

/// Parses pi (`~/.pi/agent/sessions`) and omp (`~/.omp/agent/sessions`) logs. Both
/// use the pi-ai session format: a `session` header, then `message` entries whose
/// assistant messages carry `usage {input, output, cacheRead, cacheWrite, cost}`.
struct PiParser {
    let ts = TimestampParser()

    func parse(_ data: Data, ctx: FileContext) -> (ParseOutput, Int) {
        var out = ParseOutput()
        var sessionId = ctx.sessionId
        var cwd = ctx.cwd
        let src = ctx.source
        let fileStem = URL(fileURLWithPath: ctx.path).deletingPathExtension().lastPathComponent

        let consumed = LineScanner.forEachLine(data) { line in
            if line.contains(kSession, within: headerWindow) {
                guard let d = json(line), d["type"] as? String == "session" else { return }
                if let id = d["id"] as? String { sessionId = id }
                if let c = d["cwd"] as? String { cwd = c }
                out.fileSessionId = sessionId
                out.fileCwd = cwd
                // Sub-agent transcripts get their own header but belong to the parent.
                if ctx.parentSessionId == nil, let id = sessionId {
                    out.sessions.append(SessionMeta(id: id, source: src, title: d["title"] as? String, cwd: cwd))
                }
                return
            }
            if line.contains(kTitle, within: headerWindow) || line.contains(kSessionInfo, within: headerWindow) {
                guard ctx.parentSessionId == nil, let d = json(line) else { return }
                let title = (d["title"] as? String) ?? (d["name"] as? String)
                if let title, let id = sessionId ?? idFromStem(fileStem) {
                    out.sessions.append(SessionMeta(id: id, source: src, title: title, cwd: cwd))
                }
                return
            }
            guard line.contains(kUsage), let d = json(line),
                  d["type"] as? String == "message",
                  let msg = d["message"] as? [String: Any],
                  msg["role"] as? String == "assistant",
                  let usage = msg["usage"] as? [String: Any]
            else { return }

            let owner = ctx.parentSessionId ?? sessionId ?? idFromStem(fileStem) ?? fileStem
            let entryId = (d["id"] as? String) ?? UUID().uuidString
            let key = "\(src.rawValue)|" + ((msg["responseId"] as? String).map { "r:\($0)" } ?? "\(fileStem):\(entryId)")
            let time = ts.parse(msg["timestamp"]) ?? ts.parse(d["timestamp"]) ?? Date().timeIntervalSince1970

            var row = UsageRow(key: key, source: src, sessionId: owner, project: cwd ?? "",
                               model: ModelNames.canonical((msg["model"] as? String) ?? "unknown"),
                               provider: (msg["provider"] as? String) ?? "unknown", ts: time)
            row.input = int(usage["input"])
            row.output = int(usage["output"])
            row.cacheRead = int(usage["cacheRead"])
            row.cacheWrite5m = int(usage["cacheWrite"])
            row.reasoning = int(usage["reasoningTokens"])
            row.reportedCost = double((usage["cost"] as? [String: Any])?["total"]) ?? 0
            row.kind = ctx.parentSessionId != nil ? "subagent" : "main"
            row.isError = (msg["stopReason"] as? String) == "error"
            out.usage.append(row)

            if let content = msg["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "toolCall" {
                    guard let name = block["name"] as? String else { continue }
                    let id = (block["id"] as? String) ?? "\(entryId)-\(name)"
                    out.tools.append(ToolCallRow(key: "\(src.rawValue)|\(fileStem)|\(id)", ts: time, source: src, sessionId: owner, tool: name))
                }
            }
        }
        return (out, consumed)
    }

    /// Session files are named `<ISO-timestamp>_<session-id>.jsonl`.
    func idFromStem(_ stem: String) -> String? {
        guard let underscore = stem.lastIndex(of: "_") else { return nil }
        return String(stem[stem.index(after: underscore)...])
    }
}
