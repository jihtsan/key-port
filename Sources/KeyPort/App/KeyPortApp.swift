import AppKit
import KeyPortCore
import OSLog
import SwiftUI

@main
struct KeyPortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let defaults = UserDefaults.standard
        let currentDeviceID: String
        if let storedDeviceID = defaults.string(forKey: "KeyPort.deviceID") {
            currentDeviceID = storedDeviceID
        } else {
            currentDeviceID = KeyPortNaming.newDeviceID()
            defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")
        }
        let hostV6Runtime = HostV6RuntimeAssembly.makeIfEnabled(
            currentDeviceID: currentDeviceID,
            defaults: defaults
        )
        let appModel = AppModel(hostV6Runtime: hostV6Runtime, defaults: defaults)
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

        MenuBarExtra {
            KeyPortMenuBarView(model: model)
        } label: {
            menuBarIcon
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
                .frame(width: 560, height: 420)
        }
    }

    private var menuBarIcon: some View {
        if let image = loadMenuBarImage() {
            Image(nsImage: image)
                .renderingMode(.template)
                .accessibilityLabel("KeyPort")
        } else {
            Image(systemName: "key.horizontal")
                .accessibilityLabel("KeyPort")
        }
    }

    private func loadMenuBarImage() -> NSImage? {
        let bundles = [Bundle.main, Bundle.module]
        let resourceNames = ["key-hub@2x", "key-hub@1x"]

        for bundle in bundles {
            for resourceName in resourceNames {
                guard let url = bundle.url(forResource: resourceName, withExtension: "png"),
                      let image = NSImage(contentsOf: url) else { continue }
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                return image
            }
        }

        return nil
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
