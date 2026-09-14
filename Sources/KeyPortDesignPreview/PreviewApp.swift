import AppKit
import SwiftUI
import KeyPortInterface

@main
struct DesignPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        InterfaceStyle.registerFonts()
        NSApp.setActivationPolicy(.regular)
        let window = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "KeyPort · Graph 隔离预览"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.contentView = NSHostingView(rootView: FixtureWorkspacePreview().preferredColorScheme(.light).ignoresSafeArea())
        window.minSize = NSSize(width: 1100, height: 740)
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Native window buttons stay owned by AppKit; only their titlebar placement changes.
final class PreviewWindow: NSWindow {
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let parent = standardWindowButton(.closeButton)?.superview else { return }
        var parentFrame = parent.frame
        parentFrame.size.height = 56
        if let container = parent.superview { parentFrame.origin.y = container.bounds.height - 56 }
        parent.frame = parentFrame
        for (index, kind) in kinds.enumerated() {
            guard let button = standardWindowButton(kind) else { continue }
            button.setFrameOrigin(NSPoint(x: 18 + CGFloat(index) * 20, y: (56 - button.frame.height) / 2))
        }
    }
}
