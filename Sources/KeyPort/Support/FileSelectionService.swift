import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
struct FileSelectionService {
    func selectPrivateKey() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import OpenSSH Private Key"
        panel.message = "Choose a private key with a matching .pub file."
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        return await panel.begin() == .OK ? panel.url : nil
    }

    func selectArchiveForImport() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import KeyPort Archive"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        return await panel.begin() == .OK ? panel.url : nil
    }

    func selectArchiveDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export KeyPort Metadata"
        panel.nameFieldStringValue = "KeyPort-Metadata.keyport"
        panel.allowedContentTypes = [.data]
        return await panel.begin() == .OK ? panel.url : nil
    }
}
