import Foundation

/// Top-level config.json shape: global settings plus the connection list.
/// Older releases stored a bare `[Connection]` array — ConfigStore migrates
/// those on load, so every field here must tolerate being absent.
struct AppConfig: Codable, Equatable {
    static let defaultMasterPort = 1080

    /// Fixed local port that forwards to the currently selected connection's
    /// own SOCKS listener. The port stays put while the target switches.
    var masterPort: Int
    /// Connection currently behind the master port; nil = master port off.
    var masterConnectionId: UUID?
    var connections: [Connection]

    init(masterPort: Int = AppConfig.defaultMasterPort,
         masterConnectionId: UUID? = nil,
         connections: [Connection] = []) {
        self.masterPort = masterPort
        self.masterConnectionId = masterConnectionId
        self.connections = connections
    }

    private enum CodingKeys: String, CodingKey {
        case masterPort, masterConnectionId, connections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.masterPort = try c.decodeIfPresent(Int.self, forKey: .masterPort) ?? AppConfig.defaultMasterPort
        self.masterConnectionId = try c.decodeIfPresent(UUID.self, forKey: .masterConnectionId)
        self.connections = try c.decodeIfPresent([Connection].self, forKey: .connections) ?? []
    }
}
