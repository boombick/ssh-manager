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

    /// Optional callback for AppKit consumers (the status menu) that don't observe @Published.
    var onChange: (() -> Void)?

    init(store: ConfigStore, connections: [Connection]) {
        self.store = store
        self.connections = connections

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
        var notify = false
        if fresh != stats {
            stats = fresh
            notify = true
        }
        if freshHttp != httpPorts {
            httpPorts = freshHttp
            notify = true
        }
        if notify { onChange?() }
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
        history?.flush()
    }

    // MARK: - CRUD

    func addConnection(_ c: Connection) throws {
        connections.append(c)
        try store.save(connections)
        installEngine(for: c, startIfAuto: c.autoStart)
        notifyChanged()
    }

    func updateConnection(_ c: Connection) throws {
        guard let idx = connections.firstIndex(where: { $0.id == c.id }) else { return }
        connections[idx] = c
        try store.save(connections)

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
                self.onChange?()
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
        if let e = engines[id] {
            e.stop()
            engines.removeValue(forKey: id)
        }
        connections.removeAll { $0.id == id }
        lastByteSnapshot.removeValue(forKey: id)
        httpPorts.removeValue(forKey: id)
        try store.save(connections)
        notifyChanged()
    }

    // MARK: - External edits

    /// Re-read config.json from disk. Running engines keep their existing params;
    /// to apply parameter changes from a manual edit the user must stop+start.
    func reload() {
        let fresh: [Connection]
        do {
            fresh = try store.load()
        } catch {
            NSLog("SSHManager: reload failed: \(error)")
            return
        }

        let newIDs = Set(fresh.map { $0.id })

        for (id, engine) in engines where !newIDs.contains(id) {
            engine.stop()
            engines.removeValue(forKey: id)
        }

        for c in fresh where engines[c.id] == nil {
            installEngine(for: c, startIfAuto: true)
        }

        connections = fresh
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
                self.onChange?()
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
        // but CRUD methods may also affect engine maps; nudge subscribers and AppKit menu.
        objectWillChange.send()
        refreshPingTargets()
        onChange?()
    }
}
