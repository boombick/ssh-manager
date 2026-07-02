import Foundation

enum TunnelState: Equatable {
    case stopped
    case running
    case reconnecting(attempt: Int, nextRetryAt: Date, lastError: String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

struct ByteCounters: Equatable {
    var up: UInt64 = 0
    var down: UInt64 = 0
}

/// Owns a single ssh child process and the in-process ProxyServer that sits between
/// the user-facing port and ssh's own listener. Counts bytes per direction.
final class TunnelEngine {

    /// We bind the *user-facing* port ourselves and shift ssh's own listener by this offset
    /// on the loopback interface. So `-D 1080` from the user's perspective becomes
    ///   proxy on 127.0.0.1:1080  →  ssh -D 11080  →  remote
    ///
    /// For `-R` the topology is flipped (ssh dials *us*); see start() for details.
    static let proxyPortOffset = 10000

    let connection: Connection

    private(set) var state: TunnelState = .stopped {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((TunnelState) -> Void)?

    /// Thread-safe snapshot of current byte counters since the most recent start().
    func snapshotStats() -> ByteCounters {
        statsLock.lock(); defer { statsLock.unlock() }
        return ByteCounters(up: _bytesUp, down: _bytesDown)
    }

    private var process: Process?
    private var proxy: ProxyServer?
    private var httpProxy: HttpProxyServer?
    private(set) var actualHttpProxyPort: Int?

    /// The plan computed by the most recent start(), kept for debug reports.
    private(set) var lastPlan: TunnelPlan?
    private var logHandle: FileHandle?
    private var manuallyStopped = false

    private let statsLock = NSLock()
    private var _bytesUp: UInt64 = 0
    private var _bytesDown: UInt64 = 0

    // Reconnect machinery
    private var retryTimer: DispatchSourceTimer?
    private var successUptimeTimer: DispatchSourceTimer?
    private var currentAttempt: Int = 0

    private static let backoffSchedule: [TimeInterval] = [2, 5, 10, 20, 30, 60]
    private static let maxAttempts: Int = 20
    private static let successUptimeThreshold: TimeInterval = 30

    init(connection: Connection) {
        self.connection = connection
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }
        manuallyStopped = false
        // currentAttempt is preserved when start() runs as part of a retry
        // (state is .reconnecting at that moment). Any other entry — manual
        // Start from .stopped/.failed — is a fresh series, so we zero it.
        if case .reconnecting = state {
            // keep currentAttempt as the timer / retryNow caller set it
        } else {
            currentAttempt = 0
        }
        // Cancel any pending retry — start() always wins.
        retryTimer?.cancel()
        retryTimer = nil
        resetStats()

        // Open log first so even early failures get a line.
        openLogFile()

        let plan: TunnelPlan
        do {
            plan = try planTunnel()
            lastPlan = plan
        } catch {
            writeLog("plan failed: \(error.localizedDescription)")
            let reason = error.localizedDescription
            closeLog()
            scheduleRetryOrGiveUp(reason: reason)
            return
        }

        // Bring up the proxy first. If the user-facing port is busy we want to fail
        // here, *before* we have an ssh process to clean up.
        let proxy = ProxyServer(
            listenPort: plan.proxyListenPort,
            targetHost: plan.proxyTargetHost,
            targetPort: plan.proxyTargetPort,
            connectionId: connection.id
        )
        proxy.onBytes = { [weak self] dPT, dTP in
            self?.recordBytes(deltaProxyToTarget: dPT, deltaTargetToProxy: dTP)
        }
        proxy.onListenerFailure = { [weak self] error in
            DispatchQueue.main.async {
                self?.handleProxyFailure(error)
            }
        }

        do {
            try proxy.start()
        } catch {
            writeLog("proxy bind failed on port \(plan.proxyListenPort): \(error.localizedDescription)")
            let reason = "Cannot bind port \(plan.proxyListenPort): \(error.localizedDescription)"
            closeLog()
            scheduleRetryOrGiveUp(reason: reason)
            return
        }
        self.proxy = proxy

        // Now spawn ssh.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = plan.sshArgs
        p.standardInput = FileHandle.nullDevice
        p.standardError = logHandle ?? FileHandle.nullDevice
        p.standardOutput = logHandle ?? FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async { self?.handleTermination(of: proc, exitCode: code) }
        }

        writeLog("starting: /usr/bin/ssh \(plan.sshArgs.joined(separator: " "))")
        writeLog("proxy:    listen 127.0.0.1:\(plan.proxyListenPort) → \(plan.proxyTargetHost):\(plan.proxyTargetPort)")

        do {
            try p.run()
            process = p
            state = .running
            armSuccessUptimeTimer()
        } catch {
            writeLog("failed to launch ssh: \(error.localizedDescription)")
            proxy.stop()
            self.proxy = nil
            let reason = "Failed to launch ssh: \(error.localizedDescription)"
            closeLog()
            scheduleRetryOrGiveUp(reason: reason)
            return
        }

        // Optional HTTP proxy — only for .dynamic with the toggle on.
        if connection.type == .dynamic, connection.httpProxyEnabled {
            do {
                let (port, server) = try bringUpHttpProxy(socksPort: connection.listenPort)
                actualHttpProxyPort = port
                httpProxy = server
                writeLog("http proxy: listen 127.0.0.1:\(port) → SOCKS 127.0.0.1:\(connection.listenPort)")
            } catch {
                writeLog("http proxy bring-up failed: \(error.localizedDescription)")
                let reason = "HTTP proxy: \(error.localizedDescription)"
                // Tear down ssh + SOCKS so we don't leave a half-up tunnel.
                manuallyStopped = true   // suppress termination-handler retry; we retry here ourselves.
                process?.terminate()
                process = nil
                proxy.stop()
                self.proxy = nil
                successUptimeTimer?.cancel(); successUptimeTimer = nil
                closeLog()
                scheduleRetryOrGiveUp(reason: reason)
            }
        }
    }

    func stop() {
        // Cancel any pending reconnect timer first — Stop always wins.
        retryTimer?.cancel()
        retryTimer = nil

        if case .reconnecting = state {
            // No ssh process is alive; just land in .stopped.
            currentAttempt = 0
            state = .stopped
            return
        }

        guard process != nil else {
            // Nothing running. If we're in .failed, reset to stopped so the user can retry.
            if case .failed = state { state = .stopped }
            return
        }
        manuallyStopped = true
        process?.terminate()
        // handleTermination runs on the main queue once the ssh process exits;
        // it will tear down the proxy as well.
    }

    /// User-initiated "skip the backoff" while in `.reconnecting`. Preserves the
    /// attempt counter so we don't allow infinite Retry-now spam to bypass backoff
    /// progression: if this attempt also fails, the next delay grows as usual.
    func retryNow() {
        guard case .reconnecting = state else { return }
        retryTimer?.cancel()
        retryTimer = nil
        start()
    }

    // MARK: - Private

    private func handleTermination(of proc: Process, exitCode: Int32) {
        // Осиротевший обработчик от процесса, который мы уже «списали» в
        // путях сбоя (см. handleProxyFailure): текущий запуск его не касается.
        guard proc === process else { return }
        writeLog("ssh exited with code \(exitCode)")
        proxy?.stop()
        proxy = nil
        httpProxy?.stop()
        httpProxy = nil
        actualHttpProxyPort = nil
        process = nil
        successUptimeTimer?.cancel()
        successUptimeTimer = nil

        // If handleProxyFailure (or any other path) already settled the state
        // into .reconnecting or .failed before us, leave it alone. Otherwise
        // we'd overwrite a freshly-scheduled retry with .stopped.
        switch state {
        case .reconnecting, .failed:
            closeLog()
            return
        case .stopped, .running:
            break
        }

        if manuallyStopped {
            state = .stopped
            closeLog()
            return
        }
        let reason = "ssh exited with code \(exitCode)"
        closeLog()
        scheduleRetryOrGiveUp(reason: reason)
    }

    private func handleProxyFailure(_ error: Error) {
        writeLog("proxy listener failed: \(error.localizedDescription)")
        manuallyStopped = true   // suppress "ssh exited" failure message; the proxy failed first
        process?.terminate()
        process = nil
        proxy?.stop()
        proxy = nil
        httpProxy?.stop()
        httpProxy = nil
        actualHttpProxyPort = nil
        successUptimeTimer?.cancel()
        successUptimeTimer = nil
        let reason = "Proxy: \(error.localizedDescription)"
        // manuallyStopped was set above so handleTermination won't fire retry.
        // We retry from here ourselves, treating proxy failure like ssh death.
        scheduleRetryOrGiveUp(reason: reason)
    }

    // MARK: - HTTP proxy

    /// Bring up an HTTP proxy listener that forwards via the local SOCKS5
    /// listener on `socksPort`. Honors `connection.httpProxyPort` (explicit)
    /// or auto-allocates by scanning upward from `socksPort + 1`.
    /// On success returns the bound port and a running server.
    private func bringUpHttpProxy(socksPort: Int) throws -> (port: Int, server: HttpProxyServer) {
        if let explicit = connection.httpProxyPort {
            let server = HttpProxyServer(listenPort: explicit, socksPort: socksPort, connectionId: connection.id)
            server.onListenerFailure = { [weak self] err in
                DispatchQueue.main.async { self?.handleHttpProxyFailure(err) }
            }
            try server.start()
            return (explicit, server)
        }
        // Auto: scan from socksPort+1 upward, up to 100 attempts.
        let startAt = socksPort + 1
        let maxAttempts = 100
        var port = startAt
        var tried = 0
        for _ in 0..<maxAttempts {
            guard port <= 65535 else { break }
            tried += 1
            let server = HttpProxyServer(listenPort: port, socksPort: socksPort, connectionId: connection.id)
            server.onListenerFailure = { [weak self] err in
                DispatchQueue.main.async { self?.handleHttpProxyFailure(err) }
            }
            do {
                try server.start()
                return (port, server)
            } catch {
                port += 1
            }
        }
        throw HttpProxyAllocError.noFreePort(startedAt: startAt, tried: tried)
    }

    private func handleHttpProxyFailure(_ error: Error) {
        writeLog("http proxy listener failed: \(error.localizedDescription)")
        manuallyStopped = true
        process?.terminate()
        process = nil
        proxy?.stop(); proxy = nil
        httpProxy?.stop(); httpProxy = nil
        actualHttpProxyPort = nil
        successUptimeTimer?.cancel(); successUptimeTimer = nil
        scheduleRetryOrGiveUp(reason: "HTTP proxy: \(error.localizedDescription)")
    }

    // MARK: - Reconnect

    private func scheduleRetryOrGiveUp(reason: String) {
        guard connection.autoReconnect else {
            state = .failed(reason)
            return
        }
        let nextAttempt = currentAttempt + 1
        if nextAttempt > TunnelEngine.maxAttempts {
            state = .failed("Gave up after \(TunnelEngine.maxAttempts) reconnect attempts: \(reason)")
            return
        }
        let idx = min(nextAttempt - 1, TunnelEngine.backoffSchedule.count - 1)
        let delay = TunnelEngine.backoffSchedule[idx]
        let nextAt = Date().addingTimeInterval(delay)
        currentAttempt = nextAttempt
        state = .reconnecting(attempt: nextAttempt, nextRetryAt: nextAt, lastError: reason)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // If the state moved off .reconnecting (user pressed Stop, edited
            // the connection, etc.) the timer's owner is gone; do nothing.
            guard case .reconnecting = self.state else { return }
            self.retryTimer = nil
            self.start()
        }
        retryTimer = timer
        timer.resume()
    }

    private func armSuccessUptimeTimer() {
        successUptimeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + TunnelEngine.successUptimeThreshold)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Only meaningful if we're still .running when it fires.
            if case .running = self.state {
                self.currentAttempt = 0
            }
            self.successUptimeTimer = nil
        }
        successUptimeTimer = timer
        timer.resume()
    }

    // MARK: - Stats

    private func resetStats() {
        statsLock.lock()
        _bytesUp = 0
        _bytesDown = 0
        statsLock.unlock()
    }

    private func recordBytes(deltaProxyToTarget: Int, deltaTargetToProxy: Int) {
        statsLock.lock()
        switch connection.type {
        case .dynamic, .local:
            // proxy → target = client uploading through ssh
            _bytesUp &+= UInt64(deltaProxyToTarget)
            _bytesDown &+= UInt64(deltaTargetToProxy)
        case .remote:
            // proxy receives FROM ssh (request from remote) and sends TO local service.
            // So proxy→target is "incoming through tunnel" (down), target→proxy is "outgoing" (up).
            _bytesDown &+= UInt64(deltaProxyToTarget)
            _bytesUp &+= UInt64(deltaTargetToProxy)
        }
        let up = _bytesUp, down = _bytesDown
        statsLock.unlock()
        DebugTrace.shared.trace(connection.id, "engine",
                                "recordBytes(→target: \(deltaProxyToTarget), target→: \(deltaTargetToProxy)) totals up=\(up) down=\(down)")
    }

    // MARK: - Debug introspection

    /// Live facts about this engine for the debug report. Reads process/proxy
    /// references, so call on the main queue (where all lifecycle runs).
    var sshPid: Int32? { process?.processIdentifier }
    var sshIsRunning: Bool { process?.isRunning ?? false }
    func proxyDiagnostics() -> ProxyDiagnostics? { proxy?.diagnostics() }
    func httpProxyDiagnostics() -> HttpProxyDiagnostics? { httpProxy?.diagnostics() }

    // MARK: - Planning

    struct TunnelPlan {
        let sshArgs: [String]
        let proxyListenPort: Int
        let proxyTargetHost: String
        let proxyTargetPort: Int
    }

    enum PlanError: LocalizedError {
        case listenPortOutOfRange
        case missingRemoteEndpoint
        case portOutOfRange(String)

        var errorDescription: String? {
            switch self {
            case .listenPortOutOfRange:
                return "Listen port + \(TunnelEngine.proxyPortOffset) exceeds 65535. Pick a lower port."
            case .missingRemoteEndpoint:
                return "Remote host/port are required for -L / -R tunnels."
            case .portOutOfRange(let what):
                return "\(what) must be in range 1–65535."
            }
        }
    }

    func planTunnel() throws -> TunnelPlan {
        let offset = TunnelEngine.proxyPortOffset

        // Конфиг может быть отредактирован руками — порты не валидированы UI-формой.
        // Без этих проверок UInt16(...) ниже по стеку трапается и роняет всё приложение.
        guard (1...65535).contains(connection.sshPort) else {
            throw PlanError.portOutOfRange("SSH port")
        }
        guard (1...65535).contains(connection.listenPort) else {
            throw PlanError.portOutOfRange("Listen port")
        }

        var sshOpts: [String] = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes",
        ]

        let proxyListenPort: Int
        let proxyTargetHost: String
        let proxyTargetPort: Int

        switch connection.type {
        case .dynamic:
            let sshLocalPort = connection.listenPort + offset
            guard sshLocalPort <= 65535 else { throw PlanError.listenPortOutOfRange }
            sshOpts += ["-D", "\(sshLocalPort)"]
            proxyListenPort = connection.listenPort
            proxyTargetHost = "127.0.0.1"
            proxyTargetPort = sshLocalPort

        case .local:
            guard let rh = connection.remoteHost, !rh.isEmpty,
                  let rp = connection.remotePort else {
                throw PlanError.missingRemoteEndpoint
            }
            guard (1...65535).contains(rp) else {
                throw PlanError.portOutOfRange("Remote port")
            }
            let sshLocalPort = connection.listenPort + offset
            guard sshLocalPort <= 65535 else { throw PlanError.listenPortOutOfRange }
            sshOpts += ["-L", "\(sshLocalPort):\(rh):\(rp)"]
            proxyListenPort = connection.listenPort
            proxyTargetHost = "127.0.0.1"
            proxyTargetPort = sshLocalPort

        case .remote:
            // For -R the tunnel direction is reversed: ssh DIALS into our side when a
            // remote client connects. So we make ssh dial our proxy, and the proxy dials
            // the actual local service the user wants exposed.
            //
            // remote_client → ssh_server:listenPort → tunnel → ssh_client → proxy(127.0.0.1:X) → remoteHost:remotePort
            guard let rh = connection.remoteHost, !rh.isEmpty,
                  let rp = connection.remotePort else {
                throw PlanError.missingRemoteEndpoint
            }
            guard (1...65535).contains(rp) else {
                throw PlanError.portOutOfRange("Remote port")
            }
            let proxyLocal = rp + offset
            guard proxyLocal <= 65535 else { throw PlanError.listenPortOutOfRange }
            sshOpts += ["-R", "\(connection.listenPort):localhost:\(proxyLocal)"]
            proxyListenPort = proxyLocal
            proxyTargetHost = rh    // usually "localhost" but the user may point elsewhere
            proxyTargetPort = rp
        }

        if let key = connection.identityFile, !key.isEmpty {
            let expanded = (key as NSString).expandingTildeInPath
            sshOpts += ["-i", expanded, "-o", "IdentitiesOnly=yes"]
        }
        for opt in connection.extraOptions {
            sshOpts += ["-o", opt]
        }
        sshOpts += ["-p", "\(connection.sshPort)"]
        sshOpts += ["\(connection.user)@\(connection.host)"]

        return TunnelPlan(
            sshArgs: sshOpts,
            proxyListenPort: proxyListenPort,
            proxyTargetHost: proxyTargetHost,
            proxyTargetPort: proxyTargetPort
        )
    }

    // MARK: - Logging

    private static let maxLogBytes: UInt64 = 1 * 1024 * 1024

    private func openLogFile() {
        let logURL = Paths.logFile(for: connection.id)
        let fm = FileManager.default

        // Ротация: при превышении лимита начинаем файл заново, иначе дописываем —
        // чтобы лог не стирался на каждом старте/попытке реконнекта.
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? UInt64,
           size > TunnelEngine.maxLogBytes {
            try? fm.removeItem(at: logURL)
        }
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: logURL)
        try? handle?.seekToEnd()
        logHandle = handle
    }

    private func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func writeLog(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? logHandle?.write(contentsOf: data)
    }
}

enum HttpProxyAllocError: LocalizedError {
    case noFreePort(startedAt: Int, tried: Int)
    var errorDescription: String? {
        switch self {
        case .noFreePort(let start, let tried):
            return "Could not find a free HTTP proxy port (scanned \(tried) ports starting at \(start))."
        }
    }
}
