import Network
import XCTest
@testable import SSHManager

/// Keeps one TCP connection open to a local port and pushes bytes into it.
private final class TestTcpClient {
    private let connection: NWConnection

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1",
                                  port: NWEndpoint.Port(rawValue: port)!,
                                  using: .tcp)
    }

    func connectAndSend() {
        connection.start(queue: .global())
        connection.send(content: Data("ping".utf8), completion: .contentProcessed { _ in })
    }

    func cancel() { connection.cancel() }
}

/// Accepts and holds connections open — stands in for a live SOCKS listener,
/// so pairs through the master proxy stay established.
private final class TestHoldingListener {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-hold")
    private var held: [NWConnection] = []

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.queue.async { self.held.append(conn) }
        }
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
        queue.async { self.held.forEach { $0.cancel() }; self.held.removeAll() }
    }
}

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

    /// Switching the master target must not drop the selection: re-binding the
    /// same port races with the old listener's async cancel (EADDRINUSE →
    /// onListenerFailure → reset to Off).
    func testSwitchingMasterTargetKeepsSelection() throws {
        let a = Connection(name: "a", type: .dynamic, host: "127.0.0.1",
                           sshPort: 1, user: "me", listenPort: 2081)
        let b = Connection(name: "b", type: .dynamic, host: "127.0.0.1",
                           sshPort: 1, user: "me", listenPort: 2082)
        let store = ConfigStore(url: url)
        // Not the default 1080 — a running SSH Manager instance may hold it.
        let config = AppConfig(masterPort: 2090, connections: [a, b])
        try store.save(config)
        let supervisor = TunnelSupervisor(store: store, config: config)

        // Live "SOCKS listeners" at the targets, so connections through the
        // master port actually establish and stay open — the user's "active
        // session". (Engine binds at these ports will fail; irrelevant here.)
        let holdA = try TestHoldingListener(port: 2081)
        let holdB = try TestHoldingListener(port: 2082)
        defer { holdA.cancel(); holdB.cancel() }

        try supervisor.selectMaster(id: a.id)
        XCTAssertEqual(supervisor.masterConnectionId, a.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        var clients: [TestTcpClient] = []
        defer { clients.forEach { $0.cancel() } }
        for target in [b, a, b] {
            // An established connection through the master port at switch time
            // is what makes the same-port re-bind fail (EADDRINUSE).
            let client = TestTcpClient(port: 2090)
            client.connectAndSend()
            clients.append(client)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            try supervisor.selectMaster(id: target.id)
            // The async bind failure lands on the main queue a moment later —
            // the selection must survive it, on every switch.
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(supervisor.masterConnectionId, target.id,
                           "selection reset to off after switching master target")
        }

        XCTAssertEqual(supervisor.masterDiagnostics()?.listenerState, "ready")
    }

    func testSetMasterPortPersists() throws {
        let (supervisor, _, store) = try makeSupervisor()
        try supervisor.setMasterPort(3128)
        XCTAssertEqual(supervisor.masterPort, 3128)
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.masterPort, 3128)
    }
}
