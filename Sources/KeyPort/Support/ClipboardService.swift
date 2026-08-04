import AppKit
import Foundation

@MainActor
final class ClipboardService {
    func copy(_ value: String, clearAfter seconds: TimeInterval? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        let changeCount = pasteboard.changeCount
        guard let seconds else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard NSPasteboard.general.changeCount == changeCount else { return }
            NSPasteboard.general.clearContents()
        }
    }
}
