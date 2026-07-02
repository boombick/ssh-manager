import Combine
import Foundation

/// Owns all TunnelEngines for the configured connections.
/// Observable so SwiftUI views update on list changes and engine state transitions.
final class TunnelSupervisor: ObservableObject {
    private let store: ConfigStore
    @Published private(set) var connections: [Connection]
    @Published private(set) var stats: [UUID: ByteCounters] = [:]
    @Published private(set) var pings: [UUID: PingResult] = [:]
    @Published private(set) var httpPorts: [UUID: Int] = [:]
    private var engines: [UUID: TunnelEngine] = [:]
    private var statsTimer: Timer?
    private let pingMonitor = PingMonitor()
    private var pingCancellable: AnyCancellable?
    let history: HistoryStore?
    private var lastByteSnapshot: [UUID: ByteCounters] = [:]

    // Master port: one fixed local port forwarding into the selected
    // connection's own SOCKS listener. Selection persists in config.json.
    private(set) var masterPort: Int
    @Published private(set) var masterConnectionId: UUID?
    private var masterProxy: ProxyServer?

    init(store: ConfigStore, config: AppConfig) {
        self.store = store
        self.connections = config.connections
        self.masterPort = config.masterPort
        self.masterConnectionId = config.masterConnectionId

        // History is best-effort. If the DB can't open we keep running without it.
        var openedHistory: HistoryStore?
        do {
            try? Paths.ensureSupportDirectory()
            openedHistory = try HistoryStore(url: Paths.historyFile)
        } catch {
            NSLog("SSHManager: history disabled: \(error)")
        }
        self.history = openedHistory

        // Drop everything older than 90 days. Daily-equivalent for a long-running menubar app.
        openedHistory?.purgeOlderThan(seconds: 90 * 86_400)

        for c in connections {
            installEngine(for: c, startIfAuto: true)
        }
        restoreMasterSelection()
        startStatsTimer()
        startPingMonitor()
    }

    deinit {
        statsTimer?.invalidate()
        pingMonitor.stop()
    }

    private func startPingMonitor() {
        refreshPingTargets()
        pingCancellable = pingMonitor.$results
            .sink { [weak self] new in
                guard let self else { return }
                self.pings = new
                self.writeHistorySamples()
            }
        pingMonitor.start()
    }

    private func writeHistorySamples() {
        guard let history else { return }
        let now = Date()
        for c in connections {
            // Остановленные соединения не пишем — иначе плодим нулевые строки.
            guard let engine = engines[c.id], engine.state.isRunning else { continue }
            let current = engine.snapshotStats()
            let prev = lastByteSnapshot[c.id] ?? ByteCounters()
            // Counters reset to 0 on engine restart. If `current < prev` (a wrap), treat as fresh.
            let upDelta: UInt64 = current.up >= prev.up ? current.up - prev.up : current.up
            let downDelta: UInt64 = current.down >= prev.down ? current.down - prev.down : current.down
            let ping = pings[c.id]?.rttMs
            history.recordSample(
                connectionId: c.id,
                ts: now,
                pingMs: ping,
                upDelta: upDelta,
                downDelta: downDelta
            )
            lastByteSnapshot[c.id] = current
        }
    }

    private func recordStateChangeEvent(connectionId: UUID, newState: TunnelState) {
        guard let history else { return }
        switch newState {
        case .running:
            history.recordEvent(connectionId: connectionId, kind: .started)
        case .stopped:
            history.recordEvent(connectionId: connectionId, kind: .stopped)
        case .reconnecting(_, _, let lastError):
            // Каждый уход в реконнект — это смерть туннеля; фиксируем её,
            // иначе при autoReconnect обрывы не попадают в историю вовсе.
            history.recordEvent(connectionId: connectionId, kind: .failed, message: lastError)
        case .failed(let msg):
            history.recordEvent(connectionId: connectionId, kind: .failed, message: msg)
        }
    }

    private func refreshPingTargets() {
        pingMonitor.setTargets(connections.map {
            PingTarget(id: $0.id, host: $0.host, port: $0.sshPort)
        })
    }

    private func startStatsTimer() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollStats()
        }
        RunLoop.main.add(t, forMode: .common)
        statsTimer = t
    }

    private func pollStats() {
        var fresh: [UUID: ByteCounters] = [:]
        var freshHttp: [UUID: Int] = [:]
        for (id, e) in engines {
            fresh[id] = e.snapshotStats()
            if let p = e.actualHttpProxyPort {
                freshHttp[id] = p
            }
        }
        if fresh != stats {
            // Последнее звено цепочки счётчиков: если движок насчитал байты,
            // а этих строк в trace нет — разрыв между engine и UI.
            for (id, new) in fresh where new != stats[id] {
                DebugTrace.shared.trace(id, "supervisor", "published stats up=\(new.up) down=\(new.down)")
            }
            stats = fresh
        }
        if freshHttp != httpPorts {
            httpPorts = freshHttp
        }
    }

    // MARK: - Lookup

    func engine(for id: UUID) -> TunnelEngine? { engines[id] }

    func state(for id: UUID) -> TunnelState {
        engines[id]?.state ?? .stopped
    }

    // MARK: - Lifecycle

    func toggle(id: UUID) {
        guard let e = engines[id] else { return }
        switch e.state {
        case .running, .reconnecting:
            e.stop()
        case .stopped, .failed:
            e.start()
        }
    }

    func retryNow(id: UUID) {
        engines[id]?.retryNow()
    }

    // MARK: - Master port

    enum MasterPortError: LocalizedError {
        case portCollision(port: Int, connectionName: String)
        case bindFailed(port: Int, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .portCollision(let port, let name):
                return "Master port \(port) is already used as the listen port of “\(name)”. Change masterPort in config.json."
            case .bindFailed(let port, let underlying):
                return "Cannot bind master port \(port): \(underlying.localizedDescription)"
            }
        }
    }

    /// Point the master port at connection `id` (nil = off): start its engine
    /// if needed, drop all in-flight master connections, persist the choice.
    func selectMaster(id: UUID?) throws {
        tearDownMasterProxy()

        guard let id, let c = connections.first(where: { $0.id == id }), c.type == .dynamic else {
            masterConnectionId = nil
            persistConfig()
            return
        }

        // Selecting a connection means "route my traffic through it now" —
        // bring the tunnel up if it's down.
        if let e = engines[id] {
            switch e.state {
            case .stopped, .failed:        e.start()
            case .running, .reconnecting:  break
            }
        }

        do {
            try bringUpMasterProxy(target: c)
        } catch {
            masterConnectionId = nil
            persistConfig()
            throw error
        }
        masterConnectionId = id
        persistConfig()
    }

    func masterDiagnostics() -> ProxyDiagnostics? {
        masterProxy?.diagnostics()
    }

    /// Bind the master listener at the (possibly new) target. Does not touch
    /// engine lifecycles — selectMaster / updateConnection own that part.
    private func bringUpMasterProxy(target: Connection) throws {
        // The default master port equals the default SOCKS port (1080) — catch
        // that footgun before NWListener reports it asynchronously.
        if let clash = connections.first(where: { $0.listenPort == masterPort }) {
            throw MasterPortError.portCollision(port: masterPort, connectionName: clash.name)
        }

        let proxy = ProxyServer(
            listenPort: masterPort,
            targetHost: "127.0.0.1",
            targetPort: target.listenPort
        )
        proxy.onListenerFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                NSLog("SSHManager: master port listener failed: \(error)")
                self.tearDownMasterProxy()
                self.masterConnectionId = nil
                self.persistConfig()
            }
        }
        do {
            try proxy.start()
        } catch {
            throw MasterPortError.bindFailed(port: masterPort, underlying: error)
        }
        masterProxy = proxy
    }

    private func tearDownMasterProxy() {
        masterProxy?.cancelActivePairs()
        masterProxy?.stop()
        masterProxy = nil
    }

    private var currentConfig: AppConfig {
        AppConfig(masterPort: masterPort,
                  masterConnectionId: masterConnectionId,
                  connections: connections)
    }

    private func saveConfig() throws {
        try store.save(currentConfig)
    }

    /// For paths that cannot propagate errors (async callbacks). A failed
    /// write leaves the previous config on disk — recoverable, so just log.
    private func persistConfig() {
        do { try saveConfig() } catch {
            NSLog("SSHManager: config save failed: \(error)")
        }
    }

    /// Re-apply a persisted selection at startup / after reload. Invalid or
    /// failing selections are cleared so config and reality stay in sync.
    private func restoreMasterSelection() {
        guard let id = masterConnectionId else { return }
        do {
            try selectMaster(id: id)
        } catch {
            NSLog("SSHManager: master port restore failed: \(error.localizedDescription)")
        }
    }

    /// Остановка при выходе из приложения. Событие `.stopped` пишется из
    /// асинхронного handleTermination, который не успевает до завершения
    /// процесса — поэтому фиксируем `.stopped` синхронно здесь и дожидаемся
    /// сброса истории на диск.
    func shutdownForQuit() {
        for (id, e) in engines {
            switch e.state {
            case .running, .reconnecting:
                history?.recordEvent(connectionId: id, kind: .stopped)
            case .stopped, .failed:
                break
            }
            e.stop()
        }
        masterProxy?.stop()
        history?.flush()
    }

    // MARK: - CRUD

    func addConnection(_ c: Connection) throws {
        connections.append(c)
        try saveConfig()
        installEngine(for: c, startIfAuto: c.autoStart)
        notifyChanged()
    }

    func updateConnection(_ c: Connection) throws {
        guard let idx = connections.firstIndex(where: { $0.id == c.id }) else { return }
        connections[idx] = c
        try saveConfig()
        repointMasterIfNeeded(after: c)

        let oldEngine = engines[c.id]
        let wasActive: Bool
        if let st = oldEngine?.state {
            switch st {
            case .running, .reconnecting: wasActive = true
            case .stopped, .failed:       wasActive = false
            }
        } else {
            wasActive = false
        }

        // Поставить новый движок в map (он заменяет старый), но не стартовать
        // сразу — старый ssh ещё держит порт listenPort+10000, а старый
        // ProxyServer — listenPort; иначе новый бинд падает.
        installEngine(for: c, startIfAuto: false)

        guard wasActive, let oldEngine else {
            notifyChanged()
            return
        }

        // Запустить новый движок только после того, как старый реально остановится.
        oldEngine.onStateChange = { [weak self] newState in
            DispatchQueue.main.async {
                guard let self else { return }
                self.objectWillChange.send()
                self.recordStateChangeEvent(connectionId: c.id, newState: newState)
                if case .stopped = newState {
                    self.engines[c.id]?.start()
                }
            }
        }
        oldEngine.stop()
        notifyChanged()
    }

    func deleteConnection(id: UUID) throws {
        if masterConnectionId == id {
            tearDownMasterProxy()
            masterConnectionId = nil
        }
        if let e = engines[id] {
            e.stop()
            engines.removeValue(forKey: id)
        }
        connections.removeAll { $0.id == id }
        lastByteSnapshot.removeValue(forKey: id)
        httpPorts.removeValue(forKey: id)
        try saveConfig()
        notifyChanged()
    }

    /// After a connection edit: the master target's listen port or type may
    /// have changed. Re-point (or drop) the master proxy; engine lifecycle is
    /// already handled by updateConnection's stop-then-start sequencing.
    private func repointMasterIfNeeded(after c: Connection) {
        guard masterConnectionId == c.id else { return }
        tearDownMasterProxy()
        guard c.type == .dynamic else {
            masterConnectionId = nil
            persistConfig()
            return
        }
        do {
            try bringUpMasterProxy(target: c)
        } catch {
            NSLog("SSHManager: master port re-point failed: \(error.localizedDescription)")
            masterConnectionId = nil
            persistConfig()
        }
    }

    // MARK: - External edits

    /// Re-read config.json from disk. Running engines keep their existing params;
    /// to apply parameter changes from a manual edit the user must stop+start.
    func reload() {
        let freshConfig: AppConfig
        do {
            freshConfig = try store.load()
        } catch {
            NSLog("SSHManager: reload failed: \(error)")
            return
        }
        let fresh = freshConfig.connections

        let newIDs = Set(fresh.map { $0.id })

        for (id, engine) in engines where !newIDs.contains(id) {
            engine.stop()
            engines.removeValue(forKey: id)
        }

        for c in fresh where engines[c.id] == nil {
            installEngine(for: c, startIfAuto: true)
        }

        connections = fresh

        // Master settings may have been edited by hand — re-apply from scratch.
        tearDownMasterProxy()
        masterPort = freshConfig.masterPort
        masterConnectionId = freshConfig.masterConnectionId
        restoreMasterSelection()

        notifyChanged()
    }

    // MARK: - Private

    private func installEngine(for connection: Connection, startIfAuto: Bool) {
        let e = TunnelEngine(connection: connection)
        e.onStateChange = { [weak self] newState in
            DispatchQueue.main.async {
                guard let self else { return }
                // Engine state lives in TunnelEngine. Re-publish so SwiftUI re-evaluates
                // bodies that read supervisor.state(for:).
                self.objectWillChange.send()
                self.recordStateChangeEvent(connectionId: connection.id, newState: newState)
            }
        }
        engines[connection.id] = e
        if startIfAuto && connection.autoStart {
            e.start()
        }
    }

    private func notifyChanged() {
        // @Published var connections already fires objectWillChange on assignment,
        // but CRUD methods may also affect engine maps; nudge subscribers.
        objectWillChange.send()
        refreshPingTargets()
    }
}
