import Foundation
import Darwin
import Security
import KeyPortCore

/// Prepares immutable dependencies before the managed Include transaction activates them.
struct ManagedSSHPolicyInstallation {
    let home: URL
    var bundledHelper: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeyPortSSHRelay")
    var root: URL { home.appendingPathComponent(".ssh/keyport-access") }
    struct Generation {
        let entries: [SSHConfigEntry]
        let knownHosts: URL
    }
    private func directory(_ url: URL) throws {
        var s = stat()
        if lstat(url.path, &s) == 0 {
            guard s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid(), s.st_mode & 0o022 == 0 else { throw WorkspaceError.configuration }
        } else {
            guard errno == ENOENT else { throw WorkspaceError.configuration }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    private func immutable(_ data: Data, at url: URL, mode: Int = 0o600) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try SSHRelayOwnedFile.read(url, limit: max(data.count, 1)) == data else { throw WorkspaceError.configuration }
            return
        }
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    func prepareRoot() throws { try directory(home.appendingPathComponent(".ssh")); try directory(root) }
    private func verifyVersion(_ executable: URL) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(1_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw WorkspaceError.configuration }
        process.waitUntilExit()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        guard process.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == SSHPreconnectRelayRuntime.versionString else { throw WorkspaceError.configuration }
    }
    /// Explicit repair preserves damaged generated dependencies for inspection.
    /// User SSH Include/config conflicts are handled by ManagedAliasInstallation, never overwritten here.
    func quarantineDependencies() throws {
        try directory(home.appendingPathComponent(".ssh")); try directory(root)
        let backup = root.appendingPathComponent("repair-" + UUID().uuidString)
        try directory(backup)
        for name in ["bin", "generations"] {
            let source = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try directory(source)
                try FileManager.default.moveItem(at: source, to: backup.appendingPathComponent(name))
            }
        }
    }
    func prepare(plans: [SSHPolicyExecutionPlan], directEntries: [SSHConfigEntry], knownHostsLines: [String]) throws -> Generation {
        try directory(home.appendingPathComponent(".ssh")); try directory(root)
        let generations = root.appendingPathComponent("generations")
        try directory(generations)
        let events = root.appendingPathComponent("events"); try directory(events)
        var helper: URL?
        if plans.contains(where: { $0.profile.routePolicy.fixedEndpointID == nil }) {
            // Validate bundled code before copying it outside the movable application bundle.
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(bundledHelper as CFURL, [], &code) == errSecSuccess,
                  let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { throw WorkspaceError.configuration }
            let data = try Data(contentsOf: bundledHelper)
            let bin = root.appendingPathComponent("bin"); try directory(bin)
            let target = bin.appendingPathComponent("KeyPortSSHRelay-" + HostV6.CanonicalJSON.sha256(data))
            try immutable(data, at: target, mode: 0o700)
            guard FileManager.default.isExecutableFile(atPath: target.path) else { throw WorkspaceError.configuration }
            try verifyVersion(target)
            helper = target
        }
        let configurations = plans.filter { $0.profile.routePolicy.fixedEndpointID == nil }.map { plan in
            SSHPreconnectRelayConfiguration(eventsDirectory: events.path, operationID: plan.profile.id, profileID: plan.profile.id,
                target: .init(host: plan.hostKeyAlias, port: 22),
                candidates: plan.endpoints.map { .init(endpointID: $0.id, host: $0.address, port: $0.port) })
        }
        let manifest = SSHPreconnectRelayManifest(configurations: configurations)
        try manifest.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= SSHPreconnectRelayRuntime.maximumManifestBytes else { throw WorkspaceError.configuration }
        let hosts = Data((Set(knownHostsLines + plans.flatMap(\.knownHostsLines)).sorted().joined(separator: "\n") + "\n").utf8)
        let generation = generations.appendingPathComponent(HostV6.CanonicalJSON.sha256(data + hosts))
        try directory(generation)
        let manifestURL = generation.appendingPathComponent("manifest.json")
        let hostsURL = generation.appendingPathComponent("known_hosts")
        try immutable(data, at: manifestURL); try immutable(hosts, at: hostsURL)
        let entries = directEntries + plans.map { plan -> SSHConfigEntry in
            if plan.profile.routePolicy.fixedEndpointID != nil, let endpoint = plan.endpoints.first {
                return SSHConfigEntry(server: .init(name: plan.profile.sshAlias, host: endpoint.address, port: Int(endpoint.port), username: plan.username, alias: plan.profile.sshAlias), identityPath: plan.key.privateKeyPath!, policyHostKeyAlias: plan.hostKeyAlias)
            }
            return SSHConfigEntry(server: .init(name: plan.profile.sshAlias, host: plan.hostKeyAlias, port: 22, username: plan.username, alias: plan.profile.sshAlias),
                identityPath: plan.key.privateKeyPath!, relay: .init(executable: helper!.path, manifest: manifestURL.path, profileID: plan.profile.id, hostKeyAlias: plan.hostKeyAlias))
        }
        _ = try SSHConfigGenerator.policyConfig(entries: entries, knownHostsPath: hostsURL.path)
        return .init(entries: entries, knownHosts: hostsURL)
    }
}
