import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export"), args.indices.contains(i + 1) {
            let db = args.firstIndex(of: "--db").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? Store.defaultPath
            DumpMode.export(dbPath: db, to: args[i + 1])
            return
        }
        if args.contains("--dump") {
            let db = args.firstIndex(of: "--db").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? Store.defaultPath
            DumpMode.run(dbPath: db)
            return
        }
        // launchd starts a copy at login (and right after "Open at login" is switched on). If one
        // is already running, bow out with a clean exit so launchd doesn't restart us.
        if LoginItem.launchedInBackground, let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            exit(0)
        }
        // The UI is English-only, so format dates and relative times in English too, while
        // keeping the user's region conventions (24h clock, day-month order, etc.).
        if Bundle.main.bundleIdentifier != nil, Locale.current.language.languageCode != .english {
            let region = Locale.current.region?.identifier ?? "US"
            UserDefaults.standard.set("en_\(region)", forKey: "AppleLocale")
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
        TokenCounterApp.main()
    }
}

struct TokenCounterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(LoginItem.launchedInBackground ? .accessory : .regular)
        // `--appearance dark|light` overrides the system appearance (for screenshots/testing).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--appearance"), args.indices.contains(i + 1) {
            NSApplication.shared.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
        }
    }

    var body: some Scene {
        Window("Token Counter", id: "dashboard") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1240, height: 860)

        MenuBarExtra {
            MenuBarPanel().environmentObject(app)
        } label: {
            MenuBarLabel().environmentObject(app)
        }
        .menuBarExtraStyle(.window)
    }
}

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview", models = "Models", sessions = "Sessions", projects = "Projects", limits = "Limits", help = "Help"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .models: "cpu"
        case .sessions: "list.bullet.rectangle"
        case .projects: "folder"
        case .limits: "gauge.with.dots.needle.67percent"
        case .help: "questionmark.circle"
        }
    }
    /// Pages whose content depends on the agent/time-range filters.
    var isFiltered: Bool { self != .limits && self != .help }
}

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { app.page }, set: { if let p = $0 { app.page = p } })) {
                Section {
                    ForEach(Page.allCases.filter { $0 != .help }) { p in
                        Label(p.rawValue, systemImage: p.symbol).tag(p)
                    }
                }
                Section {
                    Label(Page.help.rawValue, systemImage: Page.help.symbol).tag(Page.help)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            Group {
                switch app.page {
                case .overview: OverviewPage()
                case .models: ModelsPage()
                case .sessions: SessionsPage()
                case .projects: ProjectsPage()
                case .limits: LimitsPage()
                case .help: HelpPage()
                }
            }
            .navigationTitle(app.page.rawValue)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if app.page.isFiltered {
                        Picker("Agent", selection: sourceBinding) {
                            Text("All agents").tag(Source?.none)
                            ForEach(app.installed) { s in Text(s.label).tag(Source?.some(s)) }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 130)
                        .help("Show one agent or all of them")

                        Picker("Range", selection: $app.range) {
                            ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                        .help("Time range")
                    }
                    Button { app.refreshAll() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r")
                    .help("Refresh now (⌘R)")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let err = app.storeError {
                Text("Database error: \(err)").padding(8).background(.red.opacity(0.2), in: RoundedRectangle(cornerRadius: 8)).padding()
            }
        }
    }

    private var subtitle: String {
        guard app.page.isFiltered else { return "" }
        let agent = app.sources.count == 1 ? app.sources.first!.label : "All agents"
        return "\(agent) · \(app.range == .all ? "all time" : app.range == .today ? "today" : "last \(app.range.rawValue.dropLast()) days")"
    }

    private var sourceBinding: Binding<Source?> {
        Binding(
            get: { app.sources.count == 1 ? app.sources.first : nil },
            set: { app.sources = $0.map { [$0] } ?? Set(Source.allCases) }
        )
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(app.isScanning ? Palette.warning : Palette.good).frame(width: 6, height: 6)
                Text(app.isScanning ? "Reading logs…" : "Watching \(app.installed.map(\.label).joined(separator: ", "))")
                    .lineLimit(2)
            }
            if let first = app.allTime.firstRecord {
                Text("History since \(first.formatted(date: .abbreviated, time: .omitted))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let s = app.claudeSession {
                Text("◔ \(Int(s.percent.rounded()))%").monospacedDigit()
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
        }
        // The label always exists, so it's where the app-wide "open dashboard" action lives.
        .onAppear {
            Dashboard.open = {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let today = app.allTime.today
        VStack(alignment: .leading, spacing: 12) {
            Text("Token Counter").font(.headline)

            ForEach(app.providerList) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Text(p.kind.title).font(.caption.weight(.semibold))
                        if let plan = p.plan { Text(plan).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let err = p.error {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Palette.warning).help(err)
                        }
                    }
                    if p.isEmpty {
                        Text(p.error ?? "Loading…").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(p.windows) { LimitBar(window: $0, compact: true) }
                    ForEach(p.facts.filter { $0.label == "Balance" }) { f in
                        HStack {
                            Text(f.label).foregroundStyle(.secondary)
                            Spacer()
                            if f.warning { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.critical) }
                            Text(f.value).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
                Divider()
            }

            HStack {
                stat("Today", Fmt.tokens(today.all))
                Spacer()
                stat("Est. cost", Fmt.cost(today.cost))
                Spacer()
                stat("Last hour", Fmt.tokens(app.allTime.lastHour.all))
            }

            let active = app.allTime.sessions.filter(\.isActive)
            if !active.isEmpty {
                Divider()
                Text("Active sessions").font(.caption).foregroundStyle(.secondary)
                ForEach(active.prefix(5)) { s in
                    HStack(spacing: 6) {
                        Circle().fill(Palette.good).frame(width: 6, height: 6)
                        Text(s.title ?? s.projectName).lineLimit(1)
                        Spacer()
                        Text(s.source.shortLabel).font(.caption2).foregroundStyle(.secondary)
                        Text(Fmt.tokens(s.tokens)).font(.caption.monospacedDigit())
                    }
                    .font(.callout)
                }
            }

            Divider()
            LoginItemToggle().font(.callout)
            HStack {
                Button("Open Dashboard") {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button { app.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Token Counter")
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}
