import XCTest
@testable import SSHManager

final class HistoryStoreTests: XCTestCase {
    private var tmpURL: URL!
    private var store: HistoryStore!
    private let connId = UUID()

    override func setUpWithError() throws {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-\(UUID().uuidString).db")
        store = try HistoryStore(url: tmpURL)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: tmpURL)
    }

    /// Обрыв в середине окна: started → failed → started.
    /// Аптайм должен быть < 100%, failCount == 1.
    func testUptimeAccountsForFailures() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.recordEvent(connectionId: connId, ts: t0, kind: .started)
        store.recordEvent(connectionId: connId, ts: t0.addingTimeInterval(100), kind: .failed, message: "ssh exited")
        store.recordEvent(connectionId: connId, ts: t0.addingTimeInterval(200), kind: .started)
        store.flush()

        let summary = store.summary(
            connectionId: connId,
            from: t0,
            to: t0.addingTimeInterval(400)
        )
        XCTAssertEqual(summary.failCount, 1)
        // 100 c работал, 100 с лежал, 200 с работал → 300/400 = 0.75
        XCTAssertEqual(summary.uptimeFraction, 0.75, accuracy: 0.01)
    }
}
