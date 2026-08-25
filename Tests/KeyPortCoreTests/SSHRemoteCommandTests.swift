import Foundation
import XCTest
@testable import KeyPortCore

/// 闭集远端命令的形态固定证据：远端能力只经 `SSHRemoteCommand`，
/// 脚本文本与 legacy 一期逐字节一致（OpenSSHService 已切换到同一常量）。
final class SSHRemoteCommandTests: XCTestCase {
    private let keyBlob = Data("fixture-command-test-key-blob-0123456789abcdef".utf8).base64EncodedString()
    private var publicKeyLine: String {
        "ssh-ed25519 \(keyBlob) keyport:v1:key_fixture:device_fixture"
    }

    func testAuthenticationProbeHasNoStdinAndFixedArguments() {
        let spec = SSHRemoteCommand.authenticationProbe.spec
        XCTAssertEqual(spec.remoteArguments, ["exit"])
        XCTAssertNil(spec.standardInputScript)
    }

    func testMachineInspectionUsesFixedCompiledScript() {
        let spec = SSHRemoteCommand.machineInspection.spec
        XCTAssertEqual(spec.remoteArguments, ["sh", "-s"])
        let script = try! XCTUnwrap(spec.standardInputScript)
        // legacy 一期脚本的结构标记（逐字节一致性由 OpenSSHService 共享同一常量保证）。
        XCTAssertTrue(script.contains("hostname_value=$(hostname 2>/dev/null || uname -n)"))
        XCTAssertTrue(script.contains("memory_bytes_value=$(sysctl -n hw.memsize 2>/dev/null || true)"))
        XCTAssertTrue(script.contains("/^PRETTY_NAME=/"))
        XCTAssertTrue(script.contains("getconf _NPROCESSORS_ONLN"))
        XCTAssertTrue(script.contains("printf 'memory_bytes\t%s\n' \"$memory_bytes_value\""))
        XCTAssertTrue(script.hasSuffix("' \"$memory_bytes_value\""))
        XCTAssertFalse(script.contains("sudo"))
    }

    func testReadAuthorizedKeysScriptIsByteIdenticalToLegacy() {
        let spec = SSHRemoteCommand.readAuthorizedKeys.spec
        XCTAssertEqual(spec.remoteArguments, ["sh", "-s"])
        XCTAssertEqual(
            spec.standardInputScript,
            "test ! -f \"$HOME/.ssh/authorized_keys\" || cat \"$HOME/.ssh/authorized_keys\"\n"
        )
    }

    func testInstallAuthorizedKeyScriptKeepsBackupAtomicReplaceAndVerify() {
        guard let command = SSHRemoteCommand.installAuthorizedKey(publicKeyLine: publicKeyLine) else {
            return XCTFail("合法公钥必须能构造安装命令")
        }
        guard case .installAuthorizedKey(let encodedLine, let blob) = command else {
            return XCTFail("工厂必须产生 installAuthorizedKey")
        }
        XCTAssertEqual(encodedLine, Data(publicKeyLine.utf8).base64EncodedString())
        XCTAssertEqual(blob, keyBlob)

        let script = try! XCTUnwrap(command.spec.standardInputScript)
        XCTAssertTrue(script.contains("key_line=$(printf '%s' '\(encodedLine)' | base64 -d)"))
        XCTAssertTrue(script.contains("key_blob='\(keyBlob)'"))
        XCTAssertTrue(script.contains("backup=\"$auth.keyport-backup-$(date +%Y%m%d%H%M%S)\""))
        XCTAssertTrue(script.contains("mv \"$tmp\" \"$auth\""), "必须保持原子替换")
        XCTAssertTrue(script.hasPrefix("set -eu\numask 077"))
    }

    func testRevokeAuthorizedKeyScriptKeepsBackupAtomicReplaceAndPostCheck() {
        let command = SSHRemoteCommand.revokeAuthorizedKey(keyBlob: keyBlob)
        let script = try! XCTUnwrap(command.spec.standardInputScript)
        XCTAssertTrue(script.contains("awk -v blob='\(keyBlob)'"))
        XCTAssertTrue(script.contains("mv \"$tmp\" \"$auth\""))
        XCTAssertTrue(script.contains("exit 1"), "撤销后复检失败必须非零退出")
        XCTAssertEqual(command.spec.remoteArguments, ["sh", "-s"])
    }

    func testInstallFactoryRejectsUnparseablePublicKey() {
        XCTAssertNil(SSHRemoteCommand.installAuthorizedKey(publicKeyLine: "not-a-public-key"))
        XCTAssertNil(SSHRemoteCommand.installAuthorizedKey(publicKeyLine: ""))
    }

    /// 秘密永不进入命令参数或脚本：对固定 fixture 密码做全命令面扫描。
    func testNoSecretCanAppearInArgumentsOrScripts() {
        let markerPassword = "FIXTURE-SECRET-PASSWORD-7f3a9c"
        let commands: [SSHRemoteCommand] = [
            .authenticationProbe,
            .machineInspection,
            .readAuthorizedKeys,
            .installAuthorizedKey(encodedLine: "ZW5jb2RlZA==", keyBlob: keyBlob),
            .revokeAuthorizedKey(keyBlob: keyBlob),
        ]
        for command in commands {
            let spec = command.spec
            XCTAssertFalse(spec.remoteArguments.joined(separator: " ").contains(markerPassword))
            XCTAssertFalse((spec.standardInputScript ?? "").contains(markerPassword))
        }
    }
}
