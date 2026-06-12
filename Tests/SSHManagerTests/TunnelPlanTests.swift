import XCTest
@testable import SSHManager

final class TunnelPlanTests: XCTestCase {
    private func engine(_ c: Connection) -> TunnelEngine {
        TunnelEngine(connection: c)
    }

    func testDynamicPlanShiftsSshPortByOffset() throws {
        let c = Connection(name: "t", type: .dynamic, host: "h", user: "u", listenPort: 1080)
        let plan = try engine(c).planTunnel()
        XCTAssertTrue(plan.sshArgs.contains("-D"))
        XCTAssertTrue(plan.sshArgs.contains("\(1080 + TunnelEngine.proxyPortOffset)"))
        XCTAssertEqual(plan.proxyListenPort, 1080)
        XCTAssertEqual(plan.proxyTargetHost, "127.0.0.1")
        XCTAssertEqual(plan.proxyTargetPort, 1080 + TunnelEngine.proxyPortOffset)
        XCTAssertTrue(plan.sshArgs.contains("u@h"))
    }

    func testListenPortOutOfRangeThrows() {
        let c = Connection(name: "t", type: .dynamic, host: "h", user: "u", listenPort: 70000)
        XCTAssertThrowsError(try engine(c).planTunnel())
    }

    func testSshPortZeroThrows() {
        let c = Connection(name: "t", type: .dynamic, host: "h", sshPort: 0, user: "u", listenPort: 1080)
        XCTAssertThrowsError(try engine(c).planTunnel())
    }

    func testLocalMissingRemoteThrows() {
        let c = Connection(name: "t", type: .local, host: "h", user: "u", listenPort: 5433)
        XCTAssertThrowsError(try engine(c).planTunnel())
    }
}
