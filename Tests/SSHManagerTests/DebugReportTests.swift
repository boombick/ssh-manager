import XCTest
@testable import SSHManager

final class DebugReportTests: XCTestCase {

    private func makeInfo(
        counters: ByteCounters = ByteCounters(up: 123, down: 456),
        proxyDiagnostics: ProxyDiagnostics? = ProxyDiagnostics(
            listenerState: "ready", acceptedTotal: 7, activePairs: 2, onBytesCalls: 42
        ),
        httpPort: Int? = nil
    ) -> DebugReport.ConnectionInfo {
        DebugReport.ConnectionInfo(
            name: "work-socks",
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            typeDescription: "dynamic",
            stateDescription: "running",
            counters: counters,
            sshPid: 4242,
            sshIsRunning: true,
            sshArgs: "/usr/bin/ssh -N -T -D 11080 user@host",
            proxyDescription: "listen 127.0.0.1:1080 → 127.0.0.1:11080",
            proxyDiagnostics: proxyDiagnostics,
            httpProxyPort: httpPort,
            httpProxyDiagnostics: httpPort.map { _ in
                HttpProxyDiagnostics(listenerState: "ready", acceptedTotal: 3, activeTunnels: 1)
            }
        )
    }

    private func render(connections: [DebugReport.ConnectionInfo],
                        portScans: [(port: Int, output: String)] = [],
                        logTails: [(title: String, content: String)] = []) -> String {
        DebugReport.render(
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            appVersion: "0.4.1 (7)",
            osVersion: "macOS 15.5",
            debugModeEnabled: true,
            configJSON: "{\"connections\": []}",
            connections: connections,
            portScans: portScans,
            logTails: logTails
        )
    }

    func testRenderContainsHeaderAndConfig() {
        let text = render(connections: [])
        XCTAssertTrue(text.contains("SSH Manager Debug Report"))
        XCTAssertTrue(text.contains("app:        0.4.1 (7)"))
        XCTAssertTrue(text.contains("debug mode: ON"))
        XCTAssertTrue(text.contains("{\"connections\": []}"))
    }

    func testRenderConnectionSection() {
        let text = render(connections: [makeInfo()])
        XCTAssertTrue(text.contains("connection: work-socks"))
        XCTAssertTrue(text.contains("counters:    up=123 B  down=456 B"))
        XCTAssertTrue(text.contains("ssh:         pid 4242, running"))
        XCTAssertTrue(text.contains("ssh args:    /usr/bin/ssh -N -T -D 11080 user@host"))
        XCTAssertTrue(text.contains("listener=ready  accepted=7  active=2  onBytes=42"))
    }

    func testRenderWithoutProxyShowsPlaceholder() {
        let text = render(connections: [makeInfo(proxyDiagnostics: nil)])
        XCTAssertTrue(text.contains("proxy diag:  no proxy (engine not running)"))
    }

    func testRenderHttpProxyLine() {
        let text = render(connections: [makeInfo(httpPort: 1081)])
        XCTAssertTrue(text.contains("http proxy:  port 1081  listener=ready  accepted=3  tunnels=1"))
    }

    func testRenderPortScansAndLogTails() {
        let text = render(
            connections: [],
            portScans: [(port: 1080, output: "ssh  123  user  TCP 127.0.0.1:1080 (LISTEN)"),
                        (port: 11080, output: "")],
            logTails: [(title: "work — abc.log", content: "ssh exited with code 255")]
        )
        XCTAssertTrue(text.contains("lsof -nP -iTCP:1080"))
        XCTAssertTrue(text.contains("(LISTEN)"))
        XCTAssertTrue(text.contains("(no listeners or connections)"))
        XCTAssertTrue(text.contains("log tail: work — abc.log"))
        XCTAssertTrue(text.contains("ssh exited with code 255"))
    }

    func testDescribeStates() {
        XCTAssertEqual(DebugReport.describe(.stopped), "stopped")
        XCTAssertEqual(DebugReport.describe(.running), "running")
        XCTAssertTrue(DebugReport.describe(.failed("boom")).contains("boom"))
        XCTAssertTrue(DebugReport.describe(
            .reconnecting(attempt: 3, nextRetryAt: Date(), lastError: "dead")
        ).contains("attempt 3"))
    }
}
