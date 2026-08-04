import Foundation
import KeyPortCore
import Darwin

enum SSHServiceError: LocalizedError {
    case hostKeyNotConfirmed
    case hostKeyChanged
    case missingPrivateKey
    case missingPassword
    case passwordAuthenticationRejected
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .hostKeyNotConfirmed: "Confirm the server host key before authentication."
        case .hostKeyChanged: "The host key changed. Authentication was blocked."
        case .missingPrivateKey: "The selected key has no usable local private key."
        case .missingPassword: "No server password is stored in Keychain."
        case .passwordAuthenticationRejected: "Password authentication was rejected by the server."
        case .operationFailed(let message): message
        }
    }
}

actor OpenSSHService {
    private let runner: ProcessRunner
    private let paths: KeyPortPaths
    private let askPassPath: String

    init(runner: ProcessRunner, paths: KeyPortPaths = KeyPortPaths(), askPassPath: String) {
        self.runner = runner
        self.paths = paths
        self.askPassPath = askPassPath
    }

    func testPublicKey(server: ServerConnection, key: SSHKeyRecord) async throws -> Bool {
        guard !server.confirmedHostKeys.isEmpty else { throw SSHServiceError.hostKeyNotConfirmed }
        guard let identity = key.privateKeyPath else { throw SSHServiceError.missingPrivateKey }
        let result = try await runner.run("/usr/bin/ssh", arguments: commonArguments(server: server) + SSHAuthenticationPolicy.publicKeyOnlyArguments + [
            "-i", identity,
            "\(server.username)@\(server.host)",
            "exit",
        ])
        if result.succeeded { return true }
        if authenticationWasRejected(result.stderr) { return false }
        throw SSHServiceError.operationFailed(classifyAuthenticationError(result.stderr))
    }

    func testPassword(server: ServerConnection, passwordData: Data) async throws -> Bool {
        guard !server.confirmedHostKeys.isEmpty else { throw SSHServiceError.hostKeyNotConfirmed }
        let broker = try passwordBroker(passwordData: passwordData)
        defer { broker.cleanup() }
        broker.startWriter()
        let result = try await runner.run(
            "/usr/bin/ssh",
            arguments: commonArguments(server: server) + SSHAuthenticationPolicy.passwordOnlyArguments + [
                "\(server.username)@\(server.host)",
                "exit",
            ],
            environment: askPassEnvironment(broker: broker)
        )
        if result.succeeded { return true }
        if authenticationWasRejected(result.stderr) { return false }
        throw SSHServiceError.operationFailed(classifyAuthenticationError(result.stderr))
    }

    func installPublicKey(server: ServerConnection, key: SSHKeyRecord, passwordData: Data) async throws {
        guard !server.confirmedHostKeys.isEmpty else { throw SSHServiceError.hostKeyNotConfirmed }
        guard let parsed = PublicKeyParser.parse(key.publicKey) else {
            throw SSHServiceError.operationFailed("The selected public key is invalid.")
        }

        let encodedLine = Data(key.publicKey.utf8).base64EncodedString()
        let script = enrollmentScript(encodedLine: encodedLine, keyBlob: parsed.blob)
        let broker = try passwordBroker(passwordData: passwordData)
        defer { broker.cleanup() }
        broker.startWriter()
        let result = try await runner.run("/usr/bin/ssh", arguments: commonArguments(server: server) + SSHAuthenticationPolicy.passwordOnlyArguments + [
            "\(server.username)@\(server.host)",
            "sh", "-s",
        ], input: Data(script.utf8), environment: askPassEnvironment(broker: broker))
        guard result.succeeded else {
            if authenticationWasRejected(result.stderr) {
                throw SSHServiceError.passwordAuthenticationRejected
            }
            throw SSHServiceError.operationFailed(classifyAuthenticationError(result.stderr))
        }
    }

    func revokePublicKey(server: ServerConnection, fingerprint: String, publicKeyBlob: String, identityPath: String) async throws {
        guard !server.confirmedHostKeys.isEmpty else { throw SSHServiceError.hostKeyNotConfirmed }
        let script = revocationScript(keyBlob: publicKeyBlob)
        let result = try await runner.run("/usr/bin/ssh", arguments: commonArguments(server: server) + [
            "-o", "BatchMode=yes", "-i", identityPath,
            "\(server.username)@\(server.host)", "sh", "-s",
        ], input: Data(script.utf8))
        guard result.succeeded else { throw SSHServiceError.operationFailed("Remote authorization could not be revoked.") }
        _ = fingerprint
    }

    func readAuthorizedKeys(server: ServerConnection, identityPath: String) async throws -> [AuthorizedKeyLine] {
        guard !server.confirmedHostKeys.isEmpty else { throw SSHServiceError.hostKeyNotConfirmed }
        let script = "test ! -f \"$HOME/.ssh/authorized_keys\" || cat \"$HOME/.ssh/authorized_keys\"\n"
        let result = try await runner.run("/usr/bin/ssh", arguments: commonArguments(server: server) + [
            "-o", "BatchMode=yes", "-i", identityPath,
            "\(server.username)@\(server.host)", "sh", "-s",
        ], input: Data(script.utf8))
        guard result.succeeded else { throw SSHServiceError.operationFailed("The remote authorized_keys file could not be read.") }
        return AuthorizedKeysParser.parse(result.stdout)
    }

    private func commonArguments(server: ServerConnection) -> [String] {
        [
            "-T", "-p", String(server.port),
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "LogLevel=ERROR",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(paths.knownHosts.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "IdentitiesOnly=yes",
        ]
    }

    private func passwordBroker(passwordData: Data) throws -> PasswordFIFO {
        guard FileManager.default.isExecutableFile(atPath: askPassPath) else {
            throw SSHServiceError.operationFailed("KeyPort AskPass helper is unavailable.")
        }
        return try PasswordFIFO(paths: paths, passwordData: passwordData)
    }

    private func askPassEnvironment(broker: PasswordFIFO) -> [String: String] {
        [
            "SSH_ASKPASS": askPassPath,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": "keyport",
            "KEYPORT_PASSWORD_PIPE": broker.path,
        ]
    }

    private func enrollmentScript(encodedLine: String, keyBlob: String) -> String {
        """
        set -eu
        umask 077
        key_line=$(printf '%s' '\(encodedLine)' | base64 -d)
        key_blob='\(keyBlob)'
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        auth="$HOME/.ssh/authorized_keys"
        touch "$auth"
        chmod 600 "$auth"
        if awk -v blob="$key_blob" '{ for (i=1; i<=NF; i++) if ($i == blob) found=1 } END { exit(found ? 0 : 1) }' "$auth"; then
          exit 0
        fi
        backup="$auth.keyport-backup-$(date +%Y%m%d%H%M%S)"
        cp -p "$auth" "$backup"
        tmp="$auth.keyport-tmp-$$"
        trap 'rm -f "$tmp"' EXIT HUP INT TERM
        cp "$auth" "$tmp"
        printf '%s\n' "$key_line" >> "$tmp"
        chmod 600 "$tmp"
        mv "$tmp" "$auth"
        trap - EXIT HUP INT TERM
        awk -v blob="$key_blob" '{ for (i=1; i<=NF; i++) if ($i == blob) found=1 } END { exit(found ? 0 : 1) }' "$auth"
        """
    }

    private func revocationScript(keyBlob: String) -> String {
        """
        set -eu
        umask 077
        auth="$HOME/.ssh/authorized_keys"
        [ -f "$auth" ] || exit 0
        backup="$auth.keyport-backup-$(date +%Y%m%d%H%M%S)"
        cp -p "$auth" "$backup"
        tmp="$auth.keyport-tmp-$$"
        trap 'rm -f "$tmp"' EXIT HUP INT TERM
        awk -v blob='\(keyBlob)' '{ remove=0; for (i=1; i<=NF; i++) if ($i == blob) remove=1; if (!remove) print $0 }' "$auth" > "$tmp"
        chmod 600 "$tmp"
        mv "$tmp" "$auth"
        trap - EXIT HUP INT TERM
        if awk -v blob='\(keyBlob)' '{ for (i=1; i<=NF; i++) if ($i == blob) found=1 } END { exit(found ? 0 : 1) }' "$auth"; then
          exit 1
        fi
        """
    }

    private func classifyAuthenticationError(_ stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("host key verification failed") { return "Host key verification failed; authorization was blocked." }
        if lower.contains("permission denied") { return "Password authentication was rejected by the server." }
        if lower.contains("connection timed out") || lower.contains("operation timed out") { return "The SSH connection timed out." }
        if lower.contains("connection refused") { return "The SSH server refused the connection." }
        if lower.contains("could not resolve hostname") { return "The SSH server name could not be resolved." }
        if lower.contains("no route to host") { return "No network route to the SSH server is available." }
        return "The SSH authentication operation failed."
    }

    private func authenticationWasRejected(_ stderr: String) -> Bool {
        stderr.localizedCaseInsensitiveContains("permission denied")
    }
}

private final class PasswordFIFO: @unchecked Sendable {
    let path: String
    private let directory: URL
    private let lock = NSLock()
    private var passwordData: Data
    private var isActive = true

    init(paths: KeyPortPaths, passwordData: Data) throws {
        let directory = paths.applicationSupport.appendingPathComponent("runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        self.path = directory.appendingPathComponent("password.fifo").path
        self.passwordData = passwordData
        guard mkfifo(path, S_IRUSR | S_IWUSR) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw SSHServiceError.operationFailed("The protected AskPass channel could not be created.")
        }
    }

    func startWriter() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while writerIsActive {
                let descriptor = Darwin.open(path, O_WRONLY | O_NONBLOCK)
                if descriptor >= 0 {
                    guard var secret = takePassword() else {
                        Darwin.close(descriptor)
                        return
                    }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    handle.write(secret)
                    try? handle.close()
                    secret.resetBytes(in: secret.indices)
                    return
                }
                guard errno == ENXIO || errno == ENOENT else {
                    cancelWriter()
                    return
                }
                usleep(10_000)
            }
        }
    }

    func cleanup() {
        cancelWriter()
        try? FileManager.default.removeItem(at: directory)
    }

    private var writerIsActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive
    }

    private func takePassword() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return nil }
        isActive = false
        let secret = passwordData
        passwordData.resetBytes(in: passwordData.indices)
        return secret
    }

    private func cancelWriter() {
        lock.lock()
        isActive = false
        passwordData.resetBytes(in: passwordData.indices)
        lock.unlock()
    }
}
