import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
struct FileSelectionService {
    func selectArchiveForImport() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "导入 KeyPort 备份"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        return await panel.begin() == .OK ? panel.url : nil
    }

    func selectArchiveDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出 KeyPort 加密备份"
        panel.nameFieldStringValue = "KeyPort-Metadata.keyport"
        panel.allowedContentTypes = [.data]
        return await panel.begin() == .OK ? panel.url : nil
    }
}
