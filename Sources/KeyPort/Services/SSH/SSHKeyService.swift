import Foundation
import KeyPortCore

actor SSHKeyService {
    private let runner: ProcessRunner
    private let paths: KeyPortPaths

    init(runner: ProcessRunner, paths: KeyPortPaths = KeyPortPaths()) {
        self.runner = runner
        self.paths = paths
    }

    func generate(device: Device) async throws -> SSHKeyRecord {
        try paths.prepareDirectories()
        let keyID = KeyPortNaming.newKeyID()
        let path = paths.identitiesDirectory.appendingPathComponent(keyID)
        let comment = "keyport:v1:\(keyID):\(KeyPortNaming.deviceIdentifier(name: device.name))"
        let result = try await runner.run("/usr/bin/ssh-keygen", arguments: ["-q", "-t", "ed25519", "-f", path.path, "-N", "", "-C", comment])
        guard result.succeeded else { throw SSHServiceError.operationFailed("密钥生成失败。") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let publicLine = try String(contentsOf: path.appendingPathExtension("pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = PublicKeyParser.parse(publicLine) else { throw SSHServiceError.operationFailed("生成的公钥无效。") }
        return SSHKeyRecord(id: keyID, deviceID: device.id, kind: .ed25519, publicKey: publicLine, fingerprint: parsed.fingerprint, privateKeyPath: path.path, isInAgent: false, origin: .generated, isLocallyAvailable: true)
    }

}
