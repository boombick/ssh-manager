import SwiftUI

struct ConnectionListView: View {
    @ObservedObject var supervisor: TunnelSupervisor
    @State private var editing: Connection?
    @State private var addingDraft: Connection?
    @State private var statsFor: Connection?
    @State private var errorMessage: String?
    @State private var openAtLogin: Bool = LoginItem.isEnabled
    @State private var loginAlert: LoginAlert?
    @State private var suppressOpenAtLoginChange = false

    private struct LoginAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// When `true`, the alert offers an "Open Settings" button that
        /// deep-links to System Settings → General → Login Items.
        let openSettings: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 520, minHeight: 320)
        .sheet(item: $editing) { existing in
            ConnectionEditView(initial: existing, title: "Edit Connection") { updated in
                do {
                    try supervisor.updateConnection(updated)
                } catch {
                    errorMessage = "Failed to save: \(error.localizedDescription)"
                }
            }
        }
        .sheet(item: $addingDraft) { draft in
            ConnectionEditView(initial: draft, title: "New Connection") { new in
                do {
                    try supervisor.addConnection(new)
                } catch {
                    errorMessage = "Failed to add: \(error.localizedDescription)"
                }
            }
        }
        .sheet(item: $statsFor) { c in
            if let history = supervisor.history {
                StatsView(connection: c, history: history, supervisor: supervisor)
            } else {
                VStack(spacing: 12) {
                    Text("History database unavailable.").font(.headline)
                    Text("Check ~/Library/Application Support/SSHManager/history.db permissions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Close") { statsFor = nil }
                }
                .padding(24)
                .frame(minWidth: 360)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(item: $loginAlert) { alert in
            if alert.openSettings {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Open Settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel(Text("OK"))
                )
            } else {
                return Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
        }
        .onAppear {
            // Resync in case the user changed the setting in System Settings
            // while our window was closed. Setting `suppressOpenAtLoginChange`
            // first prevents the .onChange handler from round-tripping through
            // SMAppService for what is purely a UI sync.
            let truth = LoginItem.isEnabled
            if openAtLogin != truth {
                suppressOpenAtLoginChange = true
                openAtLogin = truth
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Connections")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Toggle("Open at login", isOn: $openAtLogin)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .onChange(of: openAtLogin) { newValue in
                    handleOpenAtLoginChange(newValue)
                }
            Button {
                addingDraft = .blank()
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Wire SMAppService toggle to the UI state.
    /// - On throw: revert the toggle and surface the error in an alert.
    /// - On success with `.requiresApproval`: leave toggle on, offer
    ///   to open System Settings.
    private func handleOpenAtLoginChange(_ newValue: Bool) {
        if suppressOpenAtLoginChange {
            suppressOpenAtLoginChange = false
            return
        }
        do {
            try LoginItem.setEnabled(newValue)
        } catch {
            // Revert without re-entering this handler.
            DispatchQueue.main.async {
                suppressOpenAtLoginChange = true
                openAtLogin = !newValue
            }
            loginAlert = LoginAlert(
                title: newValue ? "Couldn't enable open at login" : "Couldn't disable open at login",
                message: "\(error.localizedDescription)\n\nYou can manage login items manually in System Settings → General → Login Items.",
                openSettings: true
            )
            return
        }
        if newValue && LoginItem.requiresApproval {
            loginAlert = LoginAlert(
                title: "Approval required",
                message: "SSH Manager is registered as a login item, but macOS needs you to enable it in System Settings → General → Login Items.",
                openSettings: true
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if supervisor.connections.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "network.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No connections yet")
                    .font(.title3)
                Text("Click + to add your first tunnel.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(supervisor.connections) { c in
                        ConnectionRow(
                            connection: c,
                            state: supervisor.state(for: c.id),
                            counters: supervisor.stats[c.id] ?? ByteCounters(),
                            ping: supervisor.pings[c.id],
                            httpPort: supervisor.httpPorts[c.id],
                            onToggle: { supervisor.toggle(id: c.id) },
                            onRetryNow: { supervisor.retryNow(id: c.id) },
                            onEdit: { editing = c },
                            onShowStats: { statsFor = c },
                            onDelete: {
                                do {
                                    if statsFor?.id == c.id { statsFor = nil }
                                    try supervisor.deleteConnection(id: c.id)
                                } catch {
                                    errorMessage = "Failed to delete: \(error.localizedDescription)"
                                }
                            }
                        )
                        Divider()
                    }
                }
            }
        }
    }
}

private struct ConnectionRow: View {
    let connection: Connection
    let state: TunnelState
    let counters: ByteCounters
    let ping: PingResult?
    let httpPort: Int?
    let onToggle: () -> Void
    let onRetryNow: () -> Void
    let onEdit: () -> Void
    let onShowStats: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color(for: state))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name.isEmpty ? "(unnamed)" : connection.name)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusLine
            }
            .contentShape(Rectangle())
            .onTapGesture { onShowStats() }
            .help("Click for stats")

            Spacer()

            MetricsView(ping: ping, counters: counters, dimmed: !state.isRunning)
                .frame(minWidth: 130, alignment: .trailing)

            actionButtons

            Button("Edit") { onEdit() }

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .confirmationDialog(
                "Delete \"\(connection.name)\"?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) { }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch state {
        case .running:
            Button("Stop") { onToggle() }
                .frame(minWidth: 60)
        case .stopped, .failed:
            Button("Start") { onToggle() }
                .frame(minWidth: 60)
        case .reconnecting:
            HStack(spacing: 4) {
                Button("Retry now") { onRetryNow() }
                Button("Stop") { onToggle() }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .failed(let msg):
            Text(msg)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
        case .reconnecting(let attempt, let nextRetryAt, let lastError):
            VStack(alignment: .leading, spacing: 1) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = max(0, Int(nextRetryAt.timeIntervalSince(ctx.date).rounded(.up)))
                    Text("Reconnecting (attempt \(attempt), retry in \(secs)s)")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                Text("last: \(lastError)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .stopped, .running:
            EmptyView()
        }
    }

    private var subtitle: String {
        let target = "\(connection.user)@\(connection.host):\(connection.sshPort)"
        switch connection.type {
        case .dynamic:
            var base = "SOCKS :\(connection.listenPort)"
            if connection.httpProxyEnabled {
                let portText: String
                if let live = httpPort {
                    portText = "\(live)"
                } else if let configured = connection.httpProxyPort {
                    portText = "\(configured)"
                } else {
                    portText = "auto"
                }
                base += " · HTTP :\(portText)"
            }
            return "\(base)  ·  via \(target)"
        case .local:
            return "L :\(connection.listenPort) → \(connection.remoteHost ?? "?"):\(connection.remotePort ?? 0)  ·  via \(target)"
        case .remote:
            return "R :\(connection.listenPort) → \(connection.remoteHost ?? "?"):\(connection.remotePort ?? 0)  ·  via \(target)"
        }
    }

    private func color(for state: TunnelState) -> Color {
        switch state {
        case .stopped:      return .secondary
        case .running:      return .green
        case .reconnecting: return .yellow
        case .failed:       return .red
        }
    }
}

private struct MetricsView: View {
    let ping: PingResult?
    let counters: ByteCounters
    let dimmed: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "wave.3.right").font(.caption2)
                Text(formatPing(ping))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(pingColor(ping))
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").font(.caption2)
                Text(formatBytes(counters.up))
                    .font(.system(.caption, design: .monospaced))
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.down").font(.caption2)
                Text(formatBytes(counters.down))
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .foregroundStyle(dimmed ? .secondary : .primary)
        .monospacedDigit()
    }

    private func pingColor(_ ping: PingResult?) -> Color {
        guard let rtt = ping?.rttMs else { return .secondary }
        if dimmed { return .secondary }
        switch rtt {
        case ..<80:   return .green
        case ..<200:  return .yellow
        default:      return .red
        }
    }
}

private func formatPing(_ ping: PingResult?) -> String {
    guard let ping else { return "—" }
    guard let rtt = ping.rttMs else { return "timeout" }
    if rtt < 10 {
        return String(format: "%.1f ms", rtt)
    }
    return "\(Int(rtt.rounded())) ms"
}

func formatBytes(_ n: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(n, UInt64(Int64.max))),
                              countStyle: .binary)
}
