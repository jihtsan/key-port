import AppKit
import KeyPortCore
import Network
import OSLog
import SwiftUI

@main
struct KeyPortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "KeyPort.deviceID") == nil {
            defaults.set(KeyPortNaming.newDeviceID(), forKey: "KeyPort.deviceID")
        }
        let appModel = AppModel(defaults: defaults)
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
        let bundles = [Bundle.main, packagedResourceBundle].compactMap { $0 }
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

    private var packagedResourceBundle: Bundle? {
        let resourceBundleName = "KeyPort_KeyPort.bundle"
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent(resourceBundleName),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent(resourceBundleName),
        ]
        return candidates.compactMap { Bundle(url: $0) }.first
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.jihtsan.KeyPort", category: "Windowing")
    private let tunnelRegistry: TunnelRegistry
    private var pathMonitor: NWPathMonitor?
    private var terminationRequested = false

    override init() {
        self.tunnelRegistry = KeyPortRuntimeDependencies.production.tunnelRegistry
        super.init()
    }

    init(tunnelRegistry: TunnelRegistry) {
        self.tunnelRegistry = tunnelRegistry
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Application finished launching")
        startTunnelLifecycle()
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await tunnelRegistry.closeAll(reason: .applicationTermination)
            if result.cleanup == .pending {
                logger.error("Tunnel cleanup remains pending during application termination")
            }
            NSApp?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        pathMonitor?.cancel()
        pathMonitor = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func startTunnelLifecycle() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cleanup = await tunnelRegistry.reapLeases()
            if cleanup == .pending {
                logger.warning("A managed tunnel lease remains pending cleanup")
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await tunnelRegistry.networkEpochChanged()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.jihtsan.KeyPort.network-epoch"))
        pathMonitor = monitor
    }

    @objc private func handleWillSleep(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await tunnelRegistry.closeAll(reason: .sleep)
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
