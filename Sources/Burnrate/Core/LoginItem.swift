import AppKit
import ServiceManagement
import SwiftUI

/// Starts Burnrate at login through a per-user launch agent
/// (`Contents/Library/LaunchAgents/<plist>`). launchd starts it with `--background`
/// (menu bar only) and restarts it if it crashes, but not after a normal Quit.
enum LoginItem {
    static let plistName = "io.stepanenko.Burnrate.agent.plist"
    private static var service: SMAppService { SMAppService.agent(plistName: plistName) }
    private static let configuredKey = "loginItemConfigured"

    enum State { case enabled, disabled, needsApproval, unavailable }

    static var state: State {
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .disabled
        default: return .unavailable
        }
    }

    static func setEnabled(_ on: Bool) throws {
        if on { try service.register() } else { try service.unregister() }
        UserDefaults.standard.set(true, forKey: configuredKey)
    }

    /// Turns the login item on the first time the app runs from /Applications;
    /// after that the user's choice is respected.
    static func enableOnFirstRun() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: configuredKey) else { return }
        do {
            try setEnabled(true)
        } catch {
            NSLog("Burnrate: could not register login item: \(error)")
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// True when launchd started us at login (see the agent plist).
    static var launchedInBackground: Bool { CommandLine.arguments.contains("--background") }
}

/// Opens the dashboard from places that have no SwiftUI environment (Dock reopen, AppDelegate).
@MainActor
enum Dashboard {
    static var open: (() -> Void)?

    static func isDashboard(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("dashboard") == true
    }

    /// The Dock icon is shown only while the dashboard window is open; otherwise the app
    /// lives in the menu bar.
    static func updateActivationPolicy(closing: NSWindow? = nil) {
        let open = NSApp.windows.contains { $0 !== closing && isDashboard($0) && $0.isVisible }
        NSApp.setActivationPolicy(open ? .regular : .accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.enableOnFirstRun()
        let center = NotificationCenter.default
        // Observers are delivered on the main queue, so hopping onto the main actor is safe.
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let w = window, Dashboard.isDashboard(w) else { return }
                Dashboard.updateActivationPolicy(closing: w)
            }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let w = window, Dashboard.isDashboard(w) else { return }
                Dashboard.updateActivationPolicy()
            }
        }
        if LoginItem.launchedInBackground {
            // SwiftUI opens the dashboard window at launch; at login we only want the menu bar item.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSApp.windows.filter { Dashboard.isDashboard($0) }.forEach { $0.close() }
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { Dashboard.open?() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Toggle used in the menu bar panel and on the Help page.
struct LoginItemToggle: View {
    @State private var state = LoginItem.state
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: Binding(
                get: { state == .enabled || state == .needsApproval },
                set: { on in
                    do { try LoginItem.setEnabled(on); error = nil } catch { self.error = error.localizedDescription }
                    state = LoginItem.state
                }))
                .disabled(state == .unavailable)
            if state == .needsApproval {
                Button("Allow in System Settings › Login Items…") { LoginItem.openSystemSettings() }
                    .buttonStyle(.link).font(.caption)
            } else if state == .unavailable {
                Text("Available when the app runs from /Applications").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Palette.critical) }
        }
        .onAppear { state = LoginItem.state }
    }
}
