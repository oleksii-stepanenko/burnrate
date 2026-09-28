import Foundation
import SwiftUI

enum TimeRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "7D", month = "30D", quarter = "90D", all = "All"
    var id: String { rawValue }

    var since: Date? {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        switch self {
        case .today: return start
        case .week: return cal.date(byAdding: .day, value: -6, to: start)
        case .month: return cal.date(byAdding: .day, value: -29, to: start)
        case .quarter: return cal.date(byAdding: .day, value: -89, to: start)
        case .all: return nil
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var range: TimeRange = .month { didSet { reload() } }
    @Published var sources: Set<Source> = Set(Source.allCases) { didSet { reload() } }
    @Published var page: Page = {
        // `--page sessions` opens a specific page (handy for scripting/screenshots).
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--page"), a.indices.contains(i + 1) else { return .overview }
        return Page.allCases.first { $0.rawValue.lowercased() == a[i + 1].lowercased() } ?? .overview
    }()
    @Published var sessionSearch = ""
    @Published private(set) var data = DashboardData()
    @Published private(set) var allTime = DashboardData()
    /// Raw Claude result; `providers` holds the display form for every provider.
    @Published private(set) var limits = ClaudeLimits()
    @Published private(set) var providers: [ProviderKind: ProviderStatus] = [:]
    @Published private(set) var installed: [Source] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var lastAttempt: [ProviderKind: Date] = [:]
    @Published private(set) var dbStats: DatabaseStats?
    @Published var storeError: String?

    private(set) var store: Store?
    private var timer: Timer?
    private var nextFetch: [ProviderKind: Date] = [:]
    private var failures: [ProviderKind: Int] = [:]
    private var inFlight: Set<ProviderKind> = []

    init() {
        do {
            store = try Demo.isOn ? Store(path: Demo.databasePath, demo: true) : Store()
        } catch {
            storeError = "\(error)"
        }
        Task { await start() }
    }

    var filter: Filter {
        Filter(since: range.since, sources: sources, hourly: range == .today)
    }

    /// Providers in display order, skipping ones with nothing to show.
    var providerList: [ProviderStatus] {
        ProviderKind.allCases.compactMap { providers[$0] }.filter { !$0.isEmpty || $0.kind == .claude }
    }

    var claudeSession: LimitWindow? { providers[.claude]?.windows.first { $0.id == "five_hour" } }

    private func start() async {
        guard let store else { return }
        installed = await store.installedSources()
        if Demo.isOn {
            await store.seedDemo()
            providers = Demo.providers()
            await scan(force: true)
            return
        }
        // Show the last saved readings immediately; live ones replace them as they arrive.
        for kind in ProviderKind.allCases {
            if let (ts, windows) = await store.latestLimits(provider: kind.rawValue) {
                var st = ProviderStatus(kind: kind, windows: windows.filter { ($0.resetsAt ?? .distantFuture) > Date() }, fetchedAt: ts)
                st.error = nil
                providers[kind] = st
            }
        }
        await scan()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Refresh.files, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.scan()
                self?.tick()
            }
        }
    }

    /// Fetches every provider whose next refresh is due.
    private func tick() {
        let now = Date()
        for kind in ProviderKind.allCases where now >= nextFetch[kind] ?? .distantPast {
            Task { await fetch(kind) }
        }
    }

    func scan(force: Bool = false) async {
        guard let store, !isScanning else { return }
        isScanning = true
        let added = await store.ingest()
        isScanning = false
        lastScan = Date()
        if added > 0 || force || data.modelRank.isEmpty { reload() }
    }

    func refreshAll() {
        Task {
            await scan(force: true)
            if Demo.isOn { return }
            let now = Date()
            for kind in ProviderKind.allCases
            where now.timeIntervalSince(lastAttempt[kind] ?? .distantPast) >= Refresh.manualMinimum {
                Task { await fetch(kind) }
            }
        }
    }

    private func fetch(_ kind: ProviderKind) async {
        guard !inFlight.contains(kind) else { return }
        inFlight.insert(kind)
        defer { inFlight.remove(kind) }
        lastAttempt[kind] = Date()
        nextFetch[kind] = Date().addingTimeInterval(kind.interval)

        let result: ProviderStatus
        switch kind {
        case .claude:
            let raw = await ClaudeLimitsClient.fetch()
            if raw.error == nil { limits = raw }
            var r = raw.status
            if raw.error != nil, let (at, windows) = ClaudeLimitsClient.omcHudCache(),
               at > (providers[.claude]?.fetchedAt ?? .distantPast) {
                r.windows = windows
                r.fetchedAt = at
                r.via = "oh-my-claudecode HUD cache"
                r.facts = providers[.claude]?.facts ?? []
                providers[.claude] = r
                await store?.recordLimits(provider: kind.rawValue, windows)
            }
            result = r
        case .copilot:
            var r = await CopilotClient.fetch()
            // Without a live token, fall back to the quota omp cached last time it ran.
            if r.error != nil, r.via == nil {
                let cached = OmpQuotaReader.read()
                if !cached.isEmpty { r = ProviderStatus(kind: .copilot, windows: cached, via: "omp cache") }
            }
            result = r
        case .openRouter:
            result = await OpenRouterClient.fetch()
        }

        if result.error == nil || providers[kind] == nil {
            providers[kind] = result
        } else {
            // Keep the last good numbers visible; just surface the error.
            providers[kind]?.error = result.error
            if providers[kind]?.plan == nil { providers[kind]?.plan = result.plan }
        }
        if result.error == nil {
            failures[kind] = 0
            if !result.windows.isEmpty, result.via != "omp cache" {
                await store?.recordLimits(provider: kind.rawValue, result.windows)
            }
        } else if result.via != nil {
            // Real failure (not "not configured"): back off exponentially.
            let n = (failures[kind] ?? 0) + 1
            failures[kind] = n
            nextFetch[kind] = Date().addingTimeInterval(min(kind.interval * pow(2, Double(n)), Refresh.maxBackoff))
        } else {
            nextFetch[kind] = Date().addingTimeInterval(Refresh.maxBackoff)
        }
    }

    func showSessions(matching text: String) {
        sessionSearch = text
        page = .sessions
    }

    func refreshStats() {
        guard let store else { return }
        Task { dbStats = await store.stats(path: Store.defaultPath) }
    }

    func reload() {
        guard let store else { return }
        let f = filter
        Task {
            let d = await store.dashboard(f)
            let all = await store.dashboard(Filter(since: nil, sources: Set(Source.allCases), hourly: false))
            self.data = d
            self.allTime = all
        }
    }

    // MARK: Colors (stable per model, independent of the current filter)

    func color(for model: String) -> Color {
        guard let idx = allTime.modelRank.firstIndex(of: model), idx < Palette.series.count else { return Palette.other }
        return Palette.series[idx]
    }

    /// Models that get their own series in charts; everything else folds into "Other".
    var namedModels: Set<String> { Set(allTime.modelRank.prefix(Palette.series.count)) }

    func seriesName(_ model: String) -> String {
        namedModels.contains(model) ? ModelNames.display(model) : "Other"
    }
}

// MARK: - CLI verification mode

enum DumpMode {
    /// `Burnrate --export out.csv [--db path]`: write all usage rows as CSV.
    static func export(dbPath: String, to path: String) {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let store = try Store(path: dbPath)
                let n = try await store.exportCSV(to: URL(fileURLWithPath: path))
                print("exported \(n) rows → \(path)")
            } catch {
                print("error: \(error)")
            }
            sem.signal()
        }
        sem.wait()
    }

    /// `Burnrate --dump [--db path]`: ingest everything and print per-source/model totals.
    static func run(dbPath: String) {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let store = try Store(path: dbPath)
                let t0 = Date()
                let added = await store.ingest()
                print("ingested \(added) rows in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s → \(dbPath)")
                let d = await store.dashboard(Filter(since: nil, sources: Set(Source.allCases), hourly: false))
                for s in d.bySource {
                    print("\(s.source.label): req=\(s.totals.requests) in=\(s.totals.input) out=\(s.totals.output) cr=\(s.totals.cacheRead) cw=\(s.totals.cacheWrite) cost=$\(String(format: "%.2f", s.totals.cost)) sessions=\(s.totals.sessions)")
                }
                for m in d.models {
                    print("  \(m.model) [\(m.sources)] req=\(m.totals.requests) in=\(m.totals.input) out=\(m.totals.output) cr=\(m.totals.cacheRead) cw=\(m.totals.cacheWrite) cost=$\(String(format: "%.2f", m.totals.cost))")
                }
                print("sessions=\(d.sessions.count) projects=\(d.projects.count) tools=\(d.tools.prefix(5).map { "\($0.name):\($0.count)" })")
                let limits = await ClaudeLimitsClient.fetch()
                print("limits plan=\(limits.plan ?? "?") error=\(limits.error ?? "none")")
                for w in limits.windows { print("  \(w.label): \(w.percent)% resets \(w.resetsAt?.description ?? "-")") }
                for p in [await CopilotClient.fetch(), await OpenRouterClient.fetch()] {
                    print("\(p.kind.title) plan=\(p.plan ?? "?") via=\(p.via ?? "-") error=\(p.error ?? "none")")
                    for w in p.windows { print("  \(w.label): \(String(format: "%.1f", w.percent))% \(w.detail ?? "")") }
                    for f in p.facts { print("  \(f.label): \(f.value)") }
                }
            } catch {
                print("error: \(error)")
            }
            sem.signal()
        }
        sem.wait()
    }
}
