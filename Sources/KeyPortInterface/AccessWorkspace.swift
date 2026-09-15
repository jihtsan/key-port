import Foundation
import Combine

public enum PathVerification: String, Equatable { case verified = "直连已验证", pending = "路径未验证", failed = "验证失败" }
public enum PathReachability: String, Equatable { case reachable = "地址可到达", unreachable = "地址不可达", unknown = "可达性未知" }

/// One record is one explicitly configured direct path. Discovery is not a path.
public struct ConfiguredAccessPath: Identifiable, Equatable {
    public let id: String
    public let deviceID: String
    public let serverID: String
    public let account: String
    public let address: String
    public let port: Int
    public var verification: PathVerification
    public var reachability: PathReachability
    public var checkedAt: Date?
    public var terminalCommand: String?
    public var sshAlias: String?
    public var profileID: String?
    public var policyMode: String?
    public var selectionSummary: String?
    public var isDefaultConnection: Bool?
    public init(id: String, deviceID: String, serverID: String, account: String, address: String, port: Int = 22,
                verification: PathVerification = .pending, reachability: PathReachability = .unknown, checkedAt: Date? = nil, terminalCommand: String? = nil, isDefaultConnection: Bool? = nil, sshAlias: String? = nil, profileID: String? = nil, policyMode: String? = nil) {
        self.id = id; self.deviceID = deviceID; self.serverID = serverID; self.account = account
        self.address = address; self.port = port; self.verification = verification; self.reachability = reachability; self.checkedAt = checkedAt
        self.terminalCommand = terminalCommand; self.isDefaultConnection = isDefaultConnection; self.sshAlias = sshAlias; self.profileID = profileID; self.policyMode = policyMode
    }
    public var endpoint: String { "\(address.contains(":") ? "[\(address)]" : address):\(port)" }
    public var authorizationKey: AccessAuthorizationKey { .init(deviceID: deviceID, serverID: serverID, account: account) }
    public var checkedLabel: String {
        guard let checkedAt else { return "尚未检测" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: checkedAt) + " CST"
    }
}

public struct AccessWorkspaceSnapshot {
    public let deviceID: String
    public var servers: [ServerNaming]
    public var configuredPaths: [ConfiguredAccessPath]
    public var authorizations: [AccessAuthorizationKey: AccessAuthorizationStatus]
    public init(deviceID: String, servers: [ServerNaming], configuredPaths: [ConfiguredAccessPath],
                authorizations: [AccessAuthorizationKey: AccessAuthorizationStatus] = [:]) {
        self.deviceID = deviceID; self.servers = servers; self.configuredPaths = configuredPaths; self.authorizations = authorizations
    }
    /// De-duplicate only entity IDs; multiple accounts/addresses remain distinct edges.
    public var graph: DirectAccessProjection {
        var nodeIDs = Set<String>(); var pathIDs = Set<String>()
        let nodes = servers.filter { nodeIDs.insert($0.id).inserted }
        let edges = configuredPaths.filter {
            $0.deviceID == deviceID && nodeIDs.contains($0.serverID) && !$0.account.isEmpty
                && AccessFormDraft.isValidHost($0.address) && (1...65535).contains($0.port) && pathIDs.insert($0.id).inserted
        }
        return DirectAccessProjection(deviceID: deviceID, servers: nodes, paths: edges)
    }
    public func authorization(for path: ConfiguredAccessPath) -> AccessAuthorizationStatus { authorizations[path.authorizationKey] ?? .absent }
}

public struct DirectAccessProjection {
    public let deviceID: String
    public let servers: [ServerNaming]
    public let paths: [ConfiguredAccessPath]
    public func matching(_ query: String) -> Self {
        let matches = servers.filter { $0.matches(query) }; let ids = Set(matches.map(\.id))
        return Self(deviceID: deviceID, servers: matches, paths: paths.filter { ids.contains($0.serverID) })
    }
}

public enum WorkspaceSelection: Equatable, Hashable { case device(String), server(String), path(String) }
public enum WorkspacePresentation { case list, graph }

/// One scene owns data, selection and search across both presentations. Persistence is supplied by its owner.
@MainActor public final class AccessWorkspace: ObservableObject {
    @Published public private(set) var snapshot: AccessWorkspaceSnapshot
    @Published public var expandedGraphServerIDs: Set<String> = []
    public let isSimulation: Bool
    @Published public var query = ""
    @Published public var presentation = WorkspacePresentation.list
    @Published public private(set) var selection: WorkspaceSelection?
    public init(snapshot: AccessWorkspaceSnapshot, selection: WorkspaceSelection? = nil, isSimulation: Bool = true) {
        self.isSimulation = isSimulation
        self.snapshot = snapshot
        select(selection)
    }
    public var graph: DirectAccessProjection { snapshot.graph }
    public var visibleGraph: DirectAccessProjection { graph.matching(query) }
    public var selectedPath: ConfiguredAccessPath? {
        guard case .path(let id) = selection else { return nil }
        return graph.paths.first { $0.id == id }
    }
    public var selectedServer: ServerNaming? {
        let id: String?
        switch selection { case .server(let value): id = value; case .path: id = selectedPath?.serverID; default: id = nil }
        return graph.servers.first { $0.id == id }
    }
    /// Addresses belong to a selected account/alias policy, even when endpoints are shared.
    public func policyChoices(for serverID: String) -> [ConfiguredAccessPath] {
        var seen = Set<String>()
        return paths(for: serverID).filter { seen.insert($0.account + "|" + ($0.sshAlias ?? "").lowercased()).inserted }
    }
    public func policyPaths(for path: ConfiguredAccessPath) -> [ConfiguredAccessPath] {
        paths(for: path.serverID).filter {
            $0.account == path.account && ($0.sshAlias ?? "").caseInsensitiveCompare(path.sshAlias ?? "") == .orderedSame
        }
    }
    public func paths(for serverID: String) -> [ConfiguredAccessPath] { graph.paths.filter { $0.serverID == serverID } }
    public func select(_ value: WorkspaceSelection?) {
        switch value {
        case .server(let id): selection = graph.servers.contains { $0.id == id } ? value : nil
        case .path(let id):
            selection = graph.paths.contains { $0.id == id } ? value : nil
            if let path = selectedPath { expandedGraphServerIDs.insert(path.serverID) }
        case .device(let id): selection = id == snapshot.deviceID ? value : nil
        case nil: selection = nil
        }
    }
    public func replaceSnapshot(_ value: AccessWorkspaceSnapshot) {
        let oldSelection = selection; snapshot = value; select(oldSelection)
    }
    public var selectionIsFilteredOut: Bool {
        guard let server = selectedServer else { return false }
        return !visibleGraph.servers.contains { $0.id == server.id }
    }
    /// Search focuses a matching node without silently discarding a saved selection.
    public var searchTargetID: String? {
        if let selectedServer, visibleGraph.servers.contains(where: { $0.id == selectedServer.id }) { return selectedServer.id }
        return visibleGraph.servers.first?.id
    }
    public func selectSearchResult() { if let id = searchTargetID { select(.server(id)) } }
    public func advanceSelection() {
        guard !visibleGraph.servers.isEmpty else { return }
        let choices: [WorkspaceSelection] = [.device(snapshot.deviceID)] + visibleGraph.servers.map { .server($0.id) } + visibleGraph.paths.map { .path($0.id) }
        guard let index = selection.flatMap({ choices.firstIndex(of: $0) }) else { select(choices.first); return }
        select(choices[(index + 1) % choices.count])
    }
}


public enum PathPrimaryAction: Equatable {
    case authorize, checkAddress, openTerminal
    var title: String {
        switch self { case .authorize: return "配置免密"; case .checkAddress: return "检查地址"; case .openTerminal: return "在终端打开" }
    }
    var symbol: String {
        switch self { case .authorize: return "key"; case .checkAddress: return "slider.horizontal.3"; case .openTerminal: return "terminal" }
    }
}

extension AccessWorkspace {
    public func primaryAction(for path: ConfiguredAccessPath) -> PathPrimaryAction {
        if path.terminalCommand != nil && snapshot.authorization(for: path) == .installed { return .openTerminal }
        if path.reachability == .unreachable { return .checkAddress }
        if snapshot.authorization(for: path) == .installed { return path.verification == .verified ? .openTerminal : .checkAddress }
        return .authorize
    }
    public func accessDraft(for path: ConfiguredAccessPath) -> AccessFormDraft? {
        guard let server = graph.servers.first(where: { $0.id == path.serverID }), graph.paths.contains(where: { $0.id == path.id }) else { return nil }
        var draft = AccessFormDraft()
        draft.profileID = path.profileID
        draft.editingEntryID = server.id; draft.alias = path.sshAlias ?? server.alias; draft.description = server.description
        draft.existingKey = snapshot.authorization(for: path) == .installed
        draft.address = path.address; draft.port = String(path.port); draft.account = path.account
        return draft
    }
}
