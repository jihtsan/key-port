import AppKit
import Foundation

@MainActor
final class ClipboardService {
    @discardableResult
    func copy(_ value: String, clearAfter seconds: TimeInterval? = nil) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(value, forType: .string)
        let changeCount = pasteboard.changeCount
        guard let seconds else { return copied }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard NSPasteboard.general.changeCount == changeCount else { return }
            NSPasteboard.general.clearContents()
        }
        return copied
    }
}
