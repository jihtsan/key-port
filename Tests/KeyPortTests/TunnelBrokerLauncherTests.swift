import Darwin
import Foundation
import KeyPortCore
@testable import KeyPort
import XCTest

final class TunnelBrokerLauncherTests: XCTestCase {
    func testUnavailableBrokerExecutableFailsClosedBeforeLaunchingAProcess() async throws {
        let launcher = OpenSSHTunnelBrokerLauncher(executablePath: "/path/that/does/not/exist")
        let configuration = TunnelBrokerConfiguration(
            localPort: 41020,
            remoteHost: "127.0.0.1",
            remotePort: 8080,
            sshHost: "ssh.example.test",
            sshPort: 22,
            username: "admin",
            identityPath: "/Users/test/.ssh/id",
            knownHostsPath: "/Users/test/.ssh/known_hosts",
            controlPath: "/Users/test/runtime/control.sock",
            leasePath: "/Users/test/runtime/lease.json"
        )

        do {
            _ = try await launcher.launch(configuration)
            XCTFail("An unavailable broker executable unexpectedly launched")
        } catch let error as TunnelBrokerLaunchError {
            XCTAssertEqual(error, .exited)
        }
    }

    func testUnsupportedTargetConfirmationIsReportedAsIndeterminate() async throws {
        let executable = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("KeyPortTunnelBroker-(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: executable)
        }
        try Data("#!/bin/sh\nprintf 'FORWARD_FAILED target_probe_indeterminate\\n'\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let launcher = OpenSSHTunnelBrokerLauncher(executablePath: executable.path)
        do {
            _ = try await launcher.launch(makeConfiguration())
            XCTFail("An indeterminate target confirmation unexpectedly launched")
        } catch let error as TunnelBrokerLaunchError {
            XCTAssertEqual(error, .targetProbeIndeterminate)
        }
    }

    func testBrokerFailureWithoutTrailingNewlinePreservesFailureCode() async throws {
        let executable = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("KeyPortTunnelBroker-unterminated-(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: executable)
        }
        try Data("#!/bin/sh\nprintf 'FORWARD_FAILED target_refused'\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let launcher = OpenSSHTunnelBrokerLauncher(executablePath: executable.path)
        do {
            _ = try await launcher.launch(makeConfiguration())
            XCTFail("An unterminated refusal unexpectedly launched")
        } catch let error as TunnelBrokerLaunchError {
            XCTAssertEqual(error, .targetRefused)
        }
    }

    func testUnexpectedBrokerExitKeepsAnUnmanagedControlSocketPending() async throws {
        let runtimeDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: runtimeDirectory)
        }
        let controlPath = runtimeDirectory.appendingPathComponent("control.sock").path
        let leasePath = runtimeDirectory.appendingPathComponent("lease.json").path
        let executable = runtimeDirectory.appendingPathComponent("broker.sh")
        let script = "#!/bin/sh\ntouch '\(controlPath)'\nprintf 'FORWARD_ESTABLISHED\\n'\nsleep 30\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let launcher = OpenSSHTunnelBrokerLauncher(executablePath: executable.path)
        let session = try await launcher.launch(
            makeConfiguration(controlPath: controlPath, leasePath: leasePath)
        )
        guard let processIdentifier = session.processIdentifier else {
            XCTFail("The broker session did not expose a process identifier")
            return
        }
        kill(processIdentifier, SIGKILL)

        let cleanup = await session.close()
        XCTAssertEqual(cleanup, .pending)
    }

    func testBrokerWithoutConfirmationFailsWithinTheReadinessBudget() async throws {
        let executable = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("KeyPortTunnelBroker-(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: executable)
        }
        try Data("#!/bin/sh\nwhile true; do sleep 1; done\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let launcher = OpenSSHTunnelBrokerLauncher(
            executablePath: executable.path,
            readinessTimeoutNanoseconds: 10_000_000
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await launcher.launch(makeConfiguration())
            XCTFail("A broker without confirmation unexpectedly launched")
        } catch let error as TunnelBrokerLaunchError {
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            XCTAssertEqual(error, .targetProbeIndeterminate)
            XCTAssertLessThan(elapsed, 1_000_000_000)
        }
    }

    func testCancellingBrokerLaunchPreservesCancellationError() async throws {
        let executable = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("KeyPortTunnelBroker-cancel-(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: executable)
        }
        try Data("#!/bin/sh\nsleep 30\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let launcher = OpenSSHTunnelBrokerLauncher(
            executablePath: executable.path,
            readinessTimeoutNanoseconds: 5_000_000_000
        )
        let launch = Task {
            try await launcher.launch(makeConfiguration())
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        launch.cancel()

        do {
            _ = try await launch.value
            XCTFail("A cancelled broker launch unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: cancellation must remain distinguishable from an exit.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func makeConfiguration(
        controlPath: String = "/Users/test/runtime/control.sock",
        leasePath: String = "/Users/test/runtime/lease.json"
    ) -> TunnelBrokerConfiguration {
        TunnelBrokerConfiguration(
            localPort: 41020,
            remoteHost: "127.0.0.1",
            remotePort: 8080,
            sshHost: "ssh.example.test",
            sshPort: 22,
            username: "admin",
            identityPath: "/Users/test/.ssh/id",
            knownHostsPath: "/Users/test/.ssh/known_hosts",
            controlPath: controlPath,
            leasePath: leasePath
        )
    }
}
