import AppKit
import OSLog
import SwiftUI

@main
struct KeyPortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let appModel = AppModel()
        _model = State(initialValue: appModel)
        AppWindowFallback.scheduleIfNeeded(model: appModel)
    }

    var body: some Scene {
        WindowGroup("SSH KeyPort", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 620)
                .task { await model.load() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { KeyPortCommands(model: model) }

        Settings {
            SettingsView(model: model)
                .frame(width: 560, height: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.jihtsan.KeyPort", category: "Windowing")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Application finished launching")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard NSApp.windows.isEmpty else {
                self.logger.info("Primary SwiftUI window is visible")
                return
            }
            self.logger.warning("No restored window; requesting a new WindowGroup window")
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
private enum AppWindowFallback {
    private static var retainedWindow: NSWindow?

    static func scheduleIfNeeded(model: AppModel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let hasVisibleContentWindow = NSApp.windows.contains { $0.isVisible && $0.contentViewController != nil }
            guard !hasVisibleContentWindow else { return }
            let rootView = ContentView(model: model)
                .frame(minWidth: 980, minHeight: 620)
                .task { await model.load() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
            window.title = "SSH KeyPort"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.minSize = NSSize(width: 980, height: 620)
            window.center()
            window.isReleasedWhenClosed = false
            retainedWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
