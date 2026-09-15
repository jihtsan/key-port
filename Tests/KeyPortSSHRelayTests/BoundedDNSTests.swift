import XCTest
@testable import KeyPortSSHRelay

final class BoundedDNSTests: XCTestCase {
    func testHungResolverTerminatesWithinParentBudget() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-\(UUID().uuidString)")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        defer { try? FileManager.default.removeItem(at: path) }
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(BoundedDNS.resolve("fixture.invalid", port: "22", deadline: start + 100_000_000, executable: path.path), [])
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 1)
    }
    func testNumericIPv4AndIPv6() {
        XCTAssertEqual(BoundedDNS.numericHosts("127.0.0.1", port: "22"), ["127.0.0.1"])
        XCTAssertEqual(BoundedDNS.numericHosts("::1", port: "22"), ["::1"])
    }
}
