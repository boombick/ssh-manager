import XCTest
@testable import SSHManager

final class MasterPortTests: XCTestCase {

    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("master-port-tests-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    /// Loopback host + closed port so PingMonitor fails fast without real network.
    private func makeSupervisor() throws -> (TunnelSupervisor, Connection, ConfigStore) {
        let conn = Connection(name: "local", type: .dynamic, host: "127.0.0.1",
                              sshPort: 1, user: "me", listenPort: 2080)
        let store = ConfigStore(url: url)
        let config = AppConfig(connections: [conn])
        try store.save(config)
        return (TunnelSupervisor(store: store, config: config), conn, store)
    }

    func testSetMasterPortValidatesRange() throws {
        let (supervisor, _, _) = try makeSupervisor()
        XCTAssertThrowsError(try supervisor.setMasterPort(0))
        XCTAssertThrowsError(try supervisor.setMasterPort(65536))
        XCTAssertEqual(supervisor.masterPort, 1080)
    }

    func testSetMasterPortRejectsCollisionWithListenPort() throws {
        let (supervisor, _, _) = try makeSupervisor()
        XCTAssertThrowsError(try supervisor.setMasterPort(2080)) { error in
            guard case TunnelSupervisor.MasterPortError.portCollision = error else {
                return XCTFail("expected portCollision, got \(error)")
            }
        }
        XCTAssertEqual(supervisor.masterPort, 1080)
    }

    func testSetMasterPortPersists() throws {
        let (supervisor, _, store) = try makeSupervisor()
        try supervisor.setMasterPort(3128)
        XCTAssertEqual(supervisor.masterPort, 3128)
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.masterPort, 3128)
    }
}
