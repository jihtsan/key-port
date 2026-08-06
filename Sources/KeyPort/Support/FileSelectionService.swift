import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
struct FileSelectionService {
    func selectPrivateKey() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "导入 OpenSSH 私钥"
        panel.message = "请选择带有匹配 .pub 文件的私钥。"
        panel.prompt = "导入"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        return await panel.begin() == .OK ? panel.url : nil
    }

    func selectArchiveForImport() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "导入 KeyPort 归档"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        return await panel.begin() == .OK ? panel.url : nil
    }

    func selectArchiveDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出 KeyPort 元数据"
        panel.nameFieldStringValue = "KeyPort-Metadata.keyport"
        panel.allowedContentTypes = [.data]
        return await panel.begin() == .OK ? panel.url : nil
    }
}
