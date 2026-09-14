import Foundation
import Observation
import KeyPortCore

/// Decryption prepares an import; only confirmImport is allowed to publish it.
@MainActor @Observable final class WorkspaceArchiveFlow: Identifiable {
    enum Step { case export, password(URL), confirm(URL, TopologySnapshot), finished }
    let id = UUID()
    private(set) var step: Step
    var password = ""
    var confirmation = ""
    private(set) var working = false
    private(set) var error: String?
    private let store: WorkspaceStore
    private let service = MetadataArchiveService()

    init(store: WorkspaceStore, source: URL? = nil) {
        self.store = store
        step = source.map(Step.password) ?? .export
    }
    var canContinue: Bool {
        guard !working else { return false }
        switch step {
        case .export: return !password.isEmpty && password == confirmation
        case .password: return !password.isEmpty
        case .confirm: return true
        case .finished: return false
        }
    }
    var passwordMismatch: Bool { !confirmation.isEmpty && password != confirmation }
    func cancel() {
        guard !working else { return }
        clearSecrets(); step = .finished; error = nil
    }
    private func clearSecrets() { password = ""; confirmation = "" }
    func export(selectDestination: () async -> URL?) async -> Bool {
        guard case .export = step, canContinue else { return false }
        working = true; error = nil
        defer { working = false; clearSecrets() }
        guard let destination = await selectDestination() else { return false }
        do {
            try await service.export(snapshot: AppSnapshot(), topology: store.topology, password: password, destination: destination)
            step = .finished
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func readImport() async {
        guard case .password(let source) = step, canContinue else { return }
        working = true; error = nil
        defer { working = false; clearSecrets() }
        do {
            let payload = try await service.importArchive(from: source, password: password)
            let topology = payload.topology ?? TopologySnapshotMigration.fromLegacy(payload.snapshot, currentDeviceID: store.state.deviceID, currentDeviceName: "此 Mac")
            step = .confirm(source, topology)
        } catch { self.error = error.localizedDescription }
    }
    func confirmImport() -> Bool {
        guard case .confirm(_, let topology) = step, canContinue else { return false }
        working = true; error = nil
        defer { working = false }
        do { try store.importMetadata(topology); step = .finished; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
