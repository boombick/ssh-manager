import XCTest
import Network
@testable import SSHManager

final class ProxyDiagnosticsTests: XCTestCase {

    /// End-to-end through the loopback: client → ProxyServer → target.
    /// Verifies the always-on diagnostics counters that the debug report shows.
    func testDiagnosticsCountAcceptAndBytes() throws {
        let queue = DispatchQueue(label: "test.proxy-diag")

        // Target: accepts and reads whatever arrives.
        let targetReceived = expectation(description: "target received bytes")
        let targetParams = NWParameters.tcp
        targetParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        let target = try NWListener(using: targetParams)
        target.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                if let data, !data.isEmpty { targetReceived.fulfill() }
            }
        }
        let targetReady = expectation(description: "target ready")
        target.stateUpdateHandler = { if case .ready = $0 { targetReady.fulfill() } }
        target.start(queue: queue)
        wait(for: [targetReady], timeout: 5)
        let targetPort = Int(target.port!.rawValue)

        // Proxy under test. Port 0 is invalid for ProxyServer, so probe a free one.
        let proxyPort = try Self.freePort()
        let proxy = ProxyServer(listenPort: proxyPort, targetHost: "127.0.0.1", targetPort: targetPort)
        let sawBytes = expectation(description: "onBytes fired")
        sawBytes.assertForOverFulfill = false
        proxy.onBytes = { pt, _ in if pt > 0 { sawBytes.fulfill() } }
        try proxy.start()

        // Client: connect through the proxy and send a few bytes.
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(proxyPort))!, using: .tcp)
        let clientReady = expectation(description: "client ready")
        client.stateUpdateHandler = { if case .ready = $0 { clientReady.fulfill() } }
        client.start(queue: queue)
        wait(for: [clientReady], timeout: 5)
        client.send(content: Data("hello".utf8), completion: .contentProcessed { _ in })

        wait(for: [sawBytes, targetReceived], timeout: 5)

        let diag = proxy.diagnostics()
        XCTAssertEqual(diag.acceptedTotal, 1)
        XCTAssertGreaterThanOrEqual(diag.onBytesCalls, 1)
        XCTAssertEqual(diag.listenerState, "ready")
        XCTAssertEqual(diag.activePairs, 1)

        client.cancel()
        proxy.stop()
        target.cancel()
    }

    /// cancelActivePairs (used by the master port on switch) must drop
    /// established pairs: the client sees its connection die.
    func testCancelActivePairsDropsEstablishedConnections() throws {
        let queue = DispatchQueue(label: "test.proxy-cancel")

        let targetParams = NWParameters.tcp
        targetParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        let target = try NWListener(using: targetParams)
        target.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in }
        }
        let targetReady = expectation(description: "target ready")
        target.stateUpdateHandler = { if case .ready = $0 { targetReady.fulfill() } }
        target.start(queue: queue)
        wait(for: [targetReady], timeout: 5)

        let proxyPort = try Self.freePort()
        let proxy = ProxyServer(listenPort: proxyPort, targetHost: "127.0.0.1",
                                targetPort: Int(target.port!.rawValue))
        try proxy.start()

        let client = NWConnection(host: "127.0.0.1",
                                  port: NWEndpoint.Port(rawValue: UInt16(proxyPort))!,
                                  using: .tcp)
        let clientDead = expectation(description: "client connection dropped")
        client.stateUpdateHandler = { state in
            if case .ready = state {
                // Push a byte so the pair definitely registers before we cancel.
                client.send(content: Data("x".utf8), completion: .contentProcessed { _ in })
                // Peer close doesn't flip NWConnection state by itself —
                // it surfaces as isComplete/error on a pending receive.
                client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
                    if isComplete || error != nil { clientDead.fulfill() }
                }
            }
        }
        client.start(queue: queue)

        // Wait until the proxy registered the pair, then hard-switch.
        let registered = expectation(description: "pair registered")
        pollUntil(queue: queue, timeout: 5, check: { proxy.diagnostics().activePairs == 1 },
                  done: registered)
        wait(for: [registered], timeout: 5)

        proxy.cancelActivePairs()
        wait(for: [clientDead], timeout: 5)

        let drained = expectation(description: "activePairs back to 0")
        pollUntil(queue: queue, timeout: 5, check: { proxy.diagnostics().activePairs == 0 },
                  done: drained)
        wait(for: [drained], timeout: 5)

        proxy.stop()
        target.cancel()
    }

    private func pollUntil(queue: DispatchQueue, timeout: TimeInterval,
                           check: @escaping () -> Bool, done: XCTestExpectation) {
        let deadline = Date().addingTimeInterval(timeout)
        func tick() {
            if check() { done.fulfill(); return }
            guard Date() < deadline else { return }
            queue.asyncAfter(deadline: .now() + 0.05) { tick() }
        }
        queue.async { tick() }
    }

    /// Bind port 0, read back the kernel-assigned port, release it.
    private static func freePort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        precondition(sock >= 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bindResult == 0)
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(sock, $0, &len)
            }
        }
        return Int(UInt16(bigEndian: out.sin_port))
    }
}
