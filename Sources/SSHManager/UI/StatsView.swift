import SwiftUI
import Charts

enum StatsRange: String, CaseIterable, Identifiable {
    case h1   = "1h"
    case h6   = "6h"
    case d1   = "24h"
    case d7   = "7d"
    case d30  = "30d"

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .h1:  return 3600
        case .h6:  return 6 * 3600
        case .d1:  return 86_400
        case .d7:  return 7 * 86_400
        case .d30: return 30 * 86_400
        }
    }
}

struct StatsView: View {
    let connection: Connection
    let history: HistoryStore
    @ObservedObject var supervisor: TunnelSupervisor
    @Environment(\.dismiss) private var dismiss

    @State private var range: StatsRange = .d1
    @State private var samples: [Sample] = []
    @State private var events: [StateEvent] = []
    @State private var summary: StatsSummary = .empty

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            rangePicker
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            summaryRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    chartsBlock
                    eventsList
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear { reload() }
        .onChange(of: range) { _ in reload() }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            reload()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name.isEmpty ? "(unnamed)" : connection.name)
                    .font(.title2).fontWeight(.semibold)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        let target = "\(connection.user)@\(connection.host):\(connection.sshPort)"
        switch connection.type {
        case .dynamic: return "SOCKS :\(connection.listenPort) · via \(target)"
        case .local:   return "L :\(connection.listenPort) → \(connection.remoteHost ?? "?"):\(connection.remotePort ?? 0) · via \(target)"
        case .remote:  return "R :\(connection.listenPort) → \(connection.remoteHost ?? "?"):\(connection.remotePort ?? 0) · via \(target)"
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(StatsRange.allCases) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var summaryRow: some View {
        HStack(spacing: 18) {
            metric("Uptime",   String(format: "%.1f%%", summary.uptimeFraction * 100))
            metric("Fails",    "\(summary.failCount)")
            metric("Avg ping", summary.avgPingMs.map { String(format: "%.0f ms", $0) } ?? "—")
            metric("↑",         formatBytes(summary.totalUp))
            metric("↓",         formatBytes(summary.totalDown))
            Spacer()
        }
        .font(.system(.callout, design: .monospaced))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
    }

    // MARK: - Charts

    private var visibleRange: ClosedRange<Date> {
        let to = Date()
        return to.addingTimeInterval(-range.duration)...to
    }

    private var failEvents: [StateEvent] {
        events.filter { $0.kind == .failed }
    }

    private var sampleIntervalSeconds: Double {
        // PingMonitor ticks every 10s. Throughput = delta / 10.
        return 10
    }

    @ViewBuilder
    private var chartsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            chartTitle("Ping (ms)")
            pingChart
                .frame(height: 140)

            chartTitle("Throughput (B/s)")
            throughputChart
                .frame(height: 110)

            chartTitle("State")
            stateBand
                .frame(height: 14)
        }
    }

    private func chartTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var pingChart: some View {
        Chart {
            ForEach(samples.indices, id: \.self) { i in
                let s = samples[i]
                if let p = s.pingMs {
                    LineMark(
                        x: .value("t", s.ts),
                        y: .value("ping", p)
                    )
                    .interpolationMethod(.monotone)
                } else {
                    PointMark(
                        x: .value("t", s.ts),
                        y: .value("ping", 0)
                    )
                    .foregroundStyle(.red)
                    .symbolSize(20)
                }
            }
            ForEach(failEvents) { e in
                RuleMark(x: .value("fail", e.ts))
                    .foregroundStyle(.red.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: visibleRange)
    }

    private var throughputChart: some View {
        Chart {
            ForEach(samples.indices, id: \.self) { i in
                let s = samples[i]
                AreaMark(
                    x: .value("t", s.ts),
                    y: .value("rate", Double(s.upDelta) / sampleIntervalSeconds)
                )
                .foregroundStyle(by: .value("dir", "↑ up"))
                AreaMark(
                    x: .value("t", s.ts),
                    y: .value("rate", Double(s.downDelta) / sampleIntervalSeconds)
                )
                .foregroundStyle(by: .value("dir", "↓ down"))
            }
            ForEach(failEvents) { e in
                RuleMark(x: .value("fail", e.ts))
                    .foregroundStyle(.red.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: visibleRange)
        .chartForegroundStyleScale([
            "↑ up":   Color.blue.opacity(0.5),
            "↓ down": Color.green.opacity(0.5),
        ])
    }

    private var stateBand: some View {
        StateBandView(
            range: visibleRange,
            events: events,
            stateAtStart: history.lastEvent(connectionId: connection.id,
                                            atOrBefore: visibleRange.lowerBound)?.kind
        )
    }

    // MARK: - Events

    private static let eventTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()

    @ViewBuilder
    private var eventsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Events").font(.caption).foregroundStyle(.secondary)
            if events.isEmpty {
                Text("No events in this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events.reversed()) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Self.eventTimeFormatter.string(from: e.ts))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)
                        Text(e.kind.rawValue)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(eventColor(for: e.kind))
                            .frame(width: 60, alignment: .leading)
                        Text(e.message ?? "")
                            .font(.caption)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func eventColor(for kind: StateEvent.Kind) -> Color {
        switch kind {
        case .started: return .green
        case .stopped: return .secondary
        case .failed:  return .red
        }
    }

    // MARK: - Data

    private func reload() {
        let to = Date()
        let from = to.addingTimeInterval(-range.duration)
        samples = history.fetchSamples(connectionId: connection.id, from: from, to: to)
        events = history.fetchEvents(connectionId: connection.id, from: from, to: to)
        summary = history.summary(connectionId: connection.id, from: from, to: to)
    }
}

extension StatsSummary {
    static let empty = StatsSummary(
        uptimeFraction: 0, failCount: 0, avgPingMs: nil, totalUp: 0, totalDown: 0
    )
}

private struct StateBandView: View {
    let range: ClosedRange<Date>
    let events: [StateEvent]
    let stateAtStart: StateEvent.Kind?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let total = range.upperBound.timeIntervalSince(range.lowerBound)
                guard total > 0 else { return }

                // Build interval list: (start, end, color)
                var current: StateEvent.Kind = stateAtStart ?? .stopped
                var cursor = range.lowerBound
                var intervals: [(Date, Date, Color)] = []
                for e in events {
                    let s = max(cursor, range.lowerBound)
                    let t = min(e.ts, range.upperBound)
                    if t > s {
                        intervals.append((s, t, color(for: current)))
                    }
                    cursor = e.ts
                    current = e.kind
                }
                // Tail to the right edge.
                if cursor < range.upperBound {
                    intervals.append((max(cursor, range.lowerBound), range.upperBound, color(for: current)))
                }

                for (s, e, c) in intervals {
                    let x0 = CGFloat((s.timeIntervalSince(range.lowerBound)) / total) * size.width
                    let x1 = CGFloat((e.timeIntervalSince(range.lowerBound)) / total) * size.width
                    let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(c))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func color(for kind: StateEvent.Kind) -> Color {
        switch kind {
        case .started: return .green.opacity(0.6)
        case .stopped: return .gray.opacity(0.35)
        case .failed:  return .red.opacity(0.6)
        }
    }
}
