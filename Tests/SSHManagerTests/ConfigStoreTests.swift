import XCTest
@testable import SSHManager

final class ConfigStoreTests: XCTestCase {

    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-store-tests-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func sampleConnection() -> Connection {
        Connection(name: "work", type: .dynamic, host: "example.com", user: "me", listenPort: 2080)
    }

    func testMissingFileCreatesDefaultConfig() throws {
        let store = ConfigStore(url: url)
        let config = try store.load()
        XCTAssertEqual(config.masterPort, 1080)
        XCTAssertNil(config.masterConnectionId)
        XCTAssertTrue(config.connections.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testLegacyArrayMigratesAndRewritesFile() throws {
        // Simulate a pre-0.5 config: bare [Connection] array on disk.
        let legacy = [sampleConnection()]
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: url)

        let store = ConfigStore(url: url)
        let config = try store.load()
        XCTAssertEqual(config.connections, legacy)
        XCTAssertEqual(config.masterPort, 1080)
        XCTAssertNil(config.masterConnectionId)

        // The file itself must now be in the new format.
        let rewritten = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: rewritten)
        XCTAssertTrue(object is [String: Any], "config.json should be a dict after migration")
        let reloaded = try store.load()
        XCTAssertEqual(reloaded, config)
    }

    func testNewFormatRoundtrip() throws {
        let conn = sampleConnection()
        let config = AppConfig(masterPort: 3128, masterConnectionId: conn.id, connections: [conn])
        let store = ConfigStore(url: url)
        try store.save(config)
        let loaded = try store.load()
        XCTAssertEqual(loaded, config)
    }

    func testNewFormatWithMissingMasterKeysDefaults() throws {
        try Data("{\"connections\": []}".utf8).write(to: url)
        let config = try ConfigStore(url: url).load()
        XCTAssertEqual(config.masterPort, 1080)
        XCTAssertNil(config.masterConnectionId)
    }
}
