import Foundation

/// Session-only debug tracing for the byte-counting chain
/// (proxy → engine → supervisor → UI). Off by default; nothing is written and
/// message autoclosures are not evaluated while disabled, so trace() calls on
/// the hot path cost one lock round-trip at most.
///
/// Each connection gets its own `logs/<uuid>.trace.log`, separate from the main
/// per-connection log so chunk-level noise doesn't rotate away ssh's stderr.
final class DebugTrace {
    static let shared = DebugTrace()

    private static let maxTraceBytes: UInt64 = 5 * 1024 * 1024

    private let lock = NSLock()
    private var _enabled = false
    private var handles: [UUID: FileHandle] = [:]
    private var written: [UUID: UInt64] = [:]

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _enabled
    }

    func setEnabled(_ on: Bool) {
        lock.lock()
        _enabled = on
        if !on {
            for h in handles.values { try? h.close() }
            handles.removeAll()
            written.removeAll()
        }
        lock.unlock()
    }

    /// `component` names the chain link ("proxy", "http-proxy", "engine", "supervisor").
    func trace(_ id: UUID, _ component: String, _ message: @autoclosure () -> String) {
        lock.lock()
        defer { lock.unlock() }
        guard _enabled else { return }

        let line = "[\(Date())] [\(component)] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }

        if let count = written[id], count > DebugTrace.maxTraceBytes {
            try? handles[id]?.close()
            handles[id] = nil
            written[id] = nil
            try? FileManager.default.removeItem(at: Paths.traceFile(for: id))
        }
        guard let handle = handleLocked(for: id) else { return }
        try? handle.write(contentsOf: data)
        written[id, default: 0] += UInt64(data.count)
    }

    // MARK: - Private

    private func handleLocked(for id: UUID) -> FileHandle? {
        if let h = handles[id] { return h }
        let url = Paths.traceFile(for: id)
        let fm = FileManager.default
        try? Paths.ensureSupportDirectory()
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        let size = (try? handle.seekToEnd()) ?? 0
        handles[id] = handle
        written[id] = size
        return handle
    }
}
