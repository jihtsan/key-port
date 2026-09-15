import AppKit
import SwiftUI

@main
struct KeyPortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("KeyPort", id: "main") {
            WorkspaceRoot().frame(minWidth: 1100, minHeight: 740).preferredColorScheme(.light)
                .ignoresSafeArea(.container, edges: .top)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 820)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
