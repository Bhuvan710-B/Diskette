import AppKit
import SwiftUI

@main
struct DisketteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) fileprivate var appDelegate
    var body: some Scene {
        WindowGroup {
            ExplorerView()
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}

// ponytail: activation via a short repeating timer — the first few invocations
// happen while SwiftUI hasn't rendered yet, so each one just reschedules itself.
// By the time a window exists the timer fires once more, activates the app,
// and tears itself down. No magic timing; just self-correcting retries.
@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleActivation()
    }

    private func scheduleActivation() {
        activationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tryActivate()
        }
    }

    private func tryActivate() {
        guard let timer = activationTimer, !NSApplication.shared.windows.isEmpty else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.mainWindow?.makeKeyAndOrderFront(nil)
        timer.invalidate()
        activationTimer = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
