import XCTest
@testable import SSHManager

final class SmokeTests: XCTestCase {
    func testConnectionBlankDefaults() {
        let c = Connection.blank()
        XCTAssertEqual(c.type, .dynamic)
        XCTAssertEqual(c.listenPort, 1080)
        XCTAssertTrue(c.autoReconnect)
        XCTAssertFalse(c.httpProxyEnabled)
    }
}
