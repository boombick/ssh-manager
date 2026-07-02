import Foundation

/// Builds the "Save Debug Report…" text file: a single human-readable dump of
/// everything needed to diagnose a tunnel remotely — engine states, byte
/// counters, proxy diagnostics, ssh process facts, lsof port scans, log tails.
///
/// `render(...)` is pure formatting over plain data so it can be unit-tested;
/// the `generate/save` layer gathers that data from the live supervisor.
enum DebugReport {

    // MARK: - Data

    struct ConnectionInfo {
        let name: String
        let id: UUID
        let typeDescription: String
        let stateDescription: String
        let counters: ByteCounters
        let sshPid: Int32?
        let sshIsRunning: Bool
        let sshArgs: String?
        let proxyDescription: String?
        let proxyDiagnostics: ProxyDiagnostics?
        let httpProxyPort: Int?
        let httpProxyDiagnostics: HttpProxyDiagnostics?
    }

    // MARK: - Rendering (pure)

    static func render(
        generatedAt: Date,
        appVersion: String,
        osVersion: String,
        debugModeEnabled: Bool,
        configJSON: String,
        connections: [ConnectionInfo],
        portScans: [(port: Int, output: String)],
        logTails: [(title: String, content: String)]
    ) -> String {
        var out: [String] = []

        out.append("SSH Manager Debug Report")
        out.append("========================")
        out.append("generated:  \(generatedAt)")
        out.append("app:        \(appVersion)")
        out.append("macOS:      \(osVersion)")
        out.append("debug mode: \(debugModeEnabled ? "ON" : "OFF")")
        out.append("")

        out.append(section("config.json"))
        out.append(configJSON.isEmpty ? "(missing or unreadable)" : configJSON)
        out.append("")

        for c in connections {
            out.append(section("connection: \(c.name) (\(c.id))"))
            out.append("type:        \(c.typeDescription)")
            out.append("state:       \(c.stateDescription)")
            out.append("counters:    up=\(c.counters.up) B  down=\(c.counters.down) B")
            if let pid = c.sshPid {
                out.append("ssh:         pid \(pid), \(c.sshIsRunning ? "running" : "NOT running")")
            } else {
                out.append("ssh:         no process")
            }
            if let args = c.sshArgs {
                out.append("ssh args:    \(args)")
            }
            if let proxy = c.proxyDescription {
                out.append("proxy:       \(proxy)")
            }
            if let d = c.proxyDiagnostics {
                out.append("proxy diag:  listener=\(d.listenerState)  accepted=\(d.acceptedTotal)  active=\(d.activePairs)  onBytes=\(d.onBytesCalls)")
            } else {
                out.append("proxy diag:  no proxy (engine not running)")
            }
            if let port = c.httpProxyPort {
                let d = c.httpProxyDiagnostics
                out.append("http proxy:  port \(port)  listener=\(d?.listenerState ?? "?")  accepted=\(d?.acceptedTotal ?? 0)  tunnels=\(d?.activeTunnels ?? 0)")
            }
            out.append("")
        }

        for scan in portScans {
            out.append(section("lsof -nP -iTCP:\(scan.port)"))
            out.append(scan.output.isEmpty ? "(no listeners or connections)" : scan.output)
            out.append("")
        }

        for tail in logTails {
            out.append(section("log tail: \(tail.title)"))
            out.append(tail.content.isEmpty ? "(empty or missing)" : tail.content)
            out.append("")
        }

        return out.joined(separator: "\n")
    }

    private static func section(_ title: String) -> String {
        "---- \(title) " + String(repeating: "-", count: max(4, 72 - title.count - 6))
    }

    // MARK: - Gathering (live app state; call on the main queue)

    static func generate(supervisor: TunnelSupervisor) -> String {
        var infos: [ConnectionInfo] = []
        var ports: Set<Int> = []
        var tails: [(String, String)] = []

        for c in supervisor.connections {
            let engine = supervisor.engine(for: c.id)
            let plan = engine?.lastPlan

            infos.append(ConnectionInfo(
                name: c.name,
                id: c.id,
                typeDescription: "\(c.type)",
                stateDescription: describe(engine?.state ?? .stopped),
                counters: engine?.snapshotStats() ?? ByteCounters(),
                sshPid: engine?.sshPid,
                sshIsRunning: engine?.sshIsRunning ?? false,
                sshArgs: plan.map { "/usr/bin/ssh " + $0.sshArgs.joined(separator: " ") },
                proxyDescription: plan.map { "listen 127.0.0.1:\($0.proxyListenPort) → \($0.proxyTargetHost):\($0.proxyTargetPort)" },
                proxyDiagnostics: engine?.proxyDiagnostics(),
                httpProxyPort: engine?.actualHttpProxyPort,
                httpProxyDiagnostics: engine?.httpProxyDiagnostics()
            ))

            ports.insert(c.listenPort)
            if let plan {
                ports.insert(plan.proxyListenPort)
                ports.insert(plan.proxyTargetPort)
            }
            if let httpPort = engine?.actualHttpProxyPort {
                ports.insert(httpPort)
            }

            tails.append(("\(c.name) — \(c.id).log",
                          tailOfFile(Paths.logFile(for: c.id))))
            let trace = tailOfFile(Paths.traceFile(for: c.id))
            if !trace.isEmpty {
                tails.append(("\(c.name) — \(c.id).trace.log", trace))
            }
        }

        let scans = ports.sorted().map { (port: $0, output: lsof(port: $0)) }

        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let appVersion = version.map { v in build.map { "\(v) (\($0))" } ?? v } ?? "unknown (dev run)"

        return render(
            generatedAt: Date(),
            appVersion: appVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            debugModeEnabled: DebugTrace.shared.isEnabled,
            configJSON: (try? String(contentsOf: Paths.configFile, encoding: .utf8)) ?? "",
            connections: infos,
            portScans: scans,
            logTails: tails
        )
    }

    /// Write the report into debug-reports/ and return the file URL.
    @discardableResult
    static func save(supervisor: TunnelSupervisor) throws -> URL {
        let text = generate(supervisor: supervisor)
        try FileManager.default.createDirectory(
            at: Paths.debugReportsDirectory, withIntermediateDirectories: true
        )
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let url = Paths.debugReportsDirectory
            .appendingPathComponent("ssh-manager-debug-\(fmt.string(from: Date())).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    static func describe(_ state: TunnelState) -> String {
        switch state {
        case .stopped: return "stopped"
        case .running: return "running"
        case .reconnecting(let attempt, let nextRetryAt, let lastError):
            return "reconnecting (attempt \(attempt), next at \(nextRetryAt)): \(lastError)"
        case .failed(let msg): return "failed: \(msg)"
        }
    }

    private static let tailBytes = 50 * 1024

    private static func tailOfFile(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0 { text = "…(truncated to last \(tailBytes / 1024) KB)…\n" + text }
        return text
    }

    /// Who is actually listening on / connected to this port. lsof exits 1
    /// with no output when nothing matches — that's a finding, not an error.
    private static func lsof(port: Int) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return "(lsof failed to launch: \(error.localizedDescription))"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
