import Foundation

enum TunnelType: String, Codable, CaseIterable {
    case dynamic
    case local
    case remote

    var displayName: String {
        switch self {
        case .dynamic: return "SOCKS (-D)"
        case .local:   return "Local (-L)"
        case .remote:  return "Remote (-R)"
        }
    }
}

struct Connection: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var type: TunnelType

    // SSH target
    var host: String
    var sshPort: Int
    var user: String
    var identityFile: String?

    // Local port the user interacts with (also what ssh listens on for -D / -L in phase 1).
    // In a later phase ProxyServer will own this port and ssh will be shifted by +10000.
    var listenPort: Int

    // For -L and -R only
    var remoteHost: String?
    var remotePort: Int?

    var autoReconnect: Bool
    var autoStart: Bool

    /// Extra ssh -o options, e.g. ["Compression=yes", "TCPKeepAlive=yes"]
    var extraOptions: [String]

    /// When true and `type == .dynamic`, a CONNECT-only HTTP proxy is brought
    /// up alongside the SOCKS listener. No-op for `.local` / `.remote`.
    var httpProxyEnabled: Bool
    /// Explicit HTTP proxy port. When nil and `httpProxyEnabled`, the engine
    /// scans for a free port starting at `listenPort + 1`.
    var httpProxyPort: Int?

    init(
        id: UUID = UUID(),
        name: String,
        type: TunnelType,
        host: String,
        sshPort: Int = 22,
        user: String,
        identityFile: String? = nil,
        listenPort: Int,
        remoteHost: String? = nil,
        remotePort: Int? = nil,
        autoReconnect: Bool = true,
        autoStart: Bool = false,
        extraOptions: [String] = [],
        httpProxyEnabled: Bool = false,
        httpProxyPort: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.sshPort = sshPort
        self.user = user
        self.identityFile = identityFile
        self.listenPort = listenPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.autoReconnect = autoReconnect
        self.autoStart = autoStart
        self.extraOptions = extraOptions
        self.httpProxyEnabled = httpProxyEnabled
        self.httpProxyPort = httpProxyPort
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type
        case host, sshPort, user, identityFile
        case listenPort, remoteHost, remotePort
        case autoReconnect, autoStart
        case extraOptions
        case httpProxyEnabled, httpProxyPort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self,       forKey: .id)
        self.name            = try c.decode(String.self,     forKey: .name)
        self.type            = try c.decode(TunnelType.self, forKey: .type)
        self.host            = try c.decode(String.self,     forKey: .host)
        self.sshPort         = try c.decode(Int.self,        forKey: .sshPort)
        self.user            = try c.decode(String.self,     forKey: .user)
        self.identityFile    = try c.decodeIfPresent(String.self, forKey: .identityFile)
        self.listenPort      = try c.decode(Int.self,        forKey: .listenPort)
        self.remoteHost      = try c.decodeIfPresent(String.self, forKey: .remoteHost)
        self.remotePort      = try c.decodeIfPresent(Int.self,    forKey: .remotePort)
        self.autoReconnect   = try c.decode(Bool.self,       forKey: .autoReconnect)
        self.autoStart       = try c.decode(Bool.self,       forKey: .autoStart)
        self.extraOptions    = try c.decode([String].self,   forKey: .extraOptions)
        // New in 0.4.0 — default for old configs.
        self.httpProxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .httpProxyEnabled) ?? false
        self.httpProxyPort    = try c.decodeIfPresent(Int.self,  forKey: .httpProxyPort)
    }
}

extension Connection {
    /// Empty template used by the "Add Connection" sheet.
    static func blank() -> Connection {
        Connection(
            name: "",
            type: .dynamic,
            host: "",
            sshPort: 22,
            user: "",
            identityFile: nil,
            listenPort: 1080,
            remoteHost: nil,
            remotePort: nil,
            autoReconnect: true,
            autoStart: false,
            extraOptions: []
        )
    }
}
