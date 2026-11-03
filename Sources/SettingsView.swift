import Charts
import SwiftUI

enum LogRange: String, CaseIterable, Identifiable {
    case hour = "Hour"
    case day = "24 hours"
    case week = "7 days"

    var id: Self { self }

    var duration: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 604_800
        }
    }

    var bucket: TimeInterval {
        switch self {
        case .hour: 300
        case .day: 3600
        case .week: 21_600
        }
    }

    var bucketLabel: String {
        switch self {
        case .hour: "5 minutes"
        case .day: "hour"
        case .week: "6 hours"
        }
    }
}

/// Everything the charts need, computed once per render from the log.
private struct LogSummary {
    struct DelayPoint: Identifiable { let id = UUID(); let date: Date; let ms: Double }
    struct Bucket: Identifiable { let id = UUID(); let start: Date; let end: Date; let counted: Int; let ignored: Int }

    let delayPoints: [DelayPoint]
    let dropoutPoints: [DelayPoint]
    let buckets: [Bucket]
    let dropouts: Int
    let ignored: Int
    let bufferIncreases: Int
    let monitoredSeconds: TimeInterval   // time with at least one app being adjusted
    let logStart: Date?                  // oldest event in the whole log
    let maxDelay: Double

    init(events: [LogEvent], range: LogRange, now: Date, currentDelay: Double) {
        let start = now.addingTimeInterval(-range.duration)
        let inRange = events.filter { $0.date >= start && $0.date <= now }

        // Delay timeline: value before the range, every change inside it, and now.
        var points: [DelayPoint] = []
        let before = events.last { $0.date < start }
        points.append(DelayPoint(date: start, ms: before?.delayMs ?? 0))
        for e in inRange { points.append(DelayPoint(date: e.date, ms: e.delayMs)) }
        points.append(DelayPoint(date: now, ms: currentDelay))
        delayPoints = points

        var monitored: TimeInterval = 0
        for (a, b) in zip(points, points.dropFirst()) where a.ms > 0 {
            monitored += b.date.timeIntervalSince(a.date)
        }
        monitoredSeconds = monitored
        maxDelay = points.map(\.ms).max() ?? 0

        let counted = inRange.filter { $0.kind == .dropout }
        let ignoredEvents = inRange.filter { $0.kind == .dropoutIgnored }
        dropouts = counted.count
        ignored = ignoredEvents.count
        bufferIncreases = inRange.filter { $0.kind == .bufferUp }.count
        dropoutPoints = counted.map { DelayPoint(date: $0.date, ms: $0.delayMs) }

        var result: [Bucket] = []
        var t = start
        while t < now {
            let end = min(t.addingTimeInterval(range.bucket), now)
            let c = counted.filter { $0.date >= t && $0.date < end }.count
            let i = ignoredEvents.filter { $0.date >= t && $0.date < end }.count
            result.append(Bucket(start: t, end: end, counted: c, ignored: i))
            t = end
        }
        buckets = result
        logStart = events.first?.date
    }
}

/// Settings window: tabs for General, Headphone EQ, and Audio health.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            EQSettingsView()
                .tabItem { Label("Headphone EQ", systemImage: "slider.vertical.3") }
            HealthView()
                .tabItem { Label("Audio health", systemImage: "waveform.path.ecg") }
        }
        .frame(minWidth: 600, minHeight: 680)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var login = LoginItem.shared
    @EnvironmentObject var mixer: Mixer

    var body: some View {
        Form {
            SetupCheckView()

            Section {
                Toggle("Open Volume Mixer at login", isOn: Binding(
                    get: { login.isEnabled || login.needsApproval },
                    set: { login.setEnabled($0) }
                ))
                if login.needsApproval {
                    HStack {
                        Label("macOS needs you to approve this in Login Items.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                        Spacer()
                        Button("Open Login Items") { login.openLoginItemsSettings() }
                    }
                }
                if let error = login.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Keep the app in ~/Applications (where the build script puts it). If you move it, turn this off and on again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(mixer.outputDevices) { device in
                    Toggle(isOn: Binding(
                        get: { !mixer.hiddenDevices.contains(device.uid) },
                        set: { mixer.setHidden(!$0, deviceUID: device.uid) }
                    )) {
                        HStack {
                            Text(device.name)
                            if device.uid == mixer.currentOutputUID {
                                Text("current").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Show in output menu")
            } footer: {
                Text("Uncheck devices you never play sound through, like monitors without speakers. The current output always appears in the menu. Only connected devices are listed here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }
}

struct HealthView: View {
    @EnvironmentObject var mixer: Mixer
    @ObservedObject private var log = EventLog.shared
    // See EQView: avoids the @State macro.
    private var rangeState = State<LogRange>(initialValue: .day)
    private var range: LogRange {
        get { rangeState.wrappedValue }
        nonmutating set { rangeState.wrappedValue = newValue }
    }
    private var confirmClearState = State<Bool>(initialValue: false)
    private var confirmClear: Bool {
        get { confirmClearState.wrappedValue }
        nonmutating set { confirmClearState.wrappedValue = newValue }
    }

    var body: some View {
        let now = Date()
        let currentDelay = mixer.isTapping ? (mixer.bufferDelayMs ?? 0) : 0
        let summary = LogSummary(events: log.events, range: range, now: now, currentDelay: currentDelay)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Audio health").font(.title2.bold())
                    Spacer()
                    Picker("Range", selection: rangeState.projectedValue) {
                        ForEach(LogRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }

                HStack(spacing: 12) {
                    StatTile(title: "Added delay now",
                             value: mixer.isTapping ? "≈ \(Int(currentDelay.rounded())) ms" : "None",
                             caption: mixer.isTapping ? "buffer only" : "no apps adjusted")
                    StatTile(title: "Dropouts",
                             value: "\(summary.dropouts)",
                             caption: summary.ignored > 0 ? "+\(summary.ignored) ignored" : "in range")
                    StatTile(title: "Monitored",
                             value: formatDuration(summary.monitoredSeconds),
                             caption: "time apps were adjusted")
                }

                DataConfidenceNote(summary: summary, range: range, now: now)

                GroupBox {
                    delayChart(summary)
                        .frame(height: 160)
                        .padding(.top, 4)
                } label: {
                    Label("Added delay", systemImage: "timer")
                }

                GroupBox {
                    dropoutChart(summary)
                        .frame(height: 140)
                        .padding(.top, 4)
                } label: {
                    Label("Dropouts per \(range.bucketLabel)", systemImage: "waveform.badge.exclamationmark")
                }

                GroupBox {
                    eventList
                        .frame(height: 220)
                } label: {
                    Label("Recent events", systemImage: "list.bullet")
                }

                HStack {
                    Button("Show log file") { log.revealInFinder() }
                    Spacer()
                    Button("Clear log…", role: .destructive) { confirmClear = true }
                }
            }
            .padding(20)
        }
        .confirmationDialog("Clear the whole log?", isPresented: confirmClearState.projectedValue) {
            Button("Clear log", role: .destructive) { log.clear() }
        } message: {
            Text("This deletes all recorded events. It can't be undone.")
        }
    }

    // MARK: Charts

    // Charts are split into small, explicitly typed pieces: big inline chart
    // expressions are too slow for the Swift type checker.

    private func delayChart(_ s: LogSummary) -> some View {
        let yMax: Double = max(25, s.maxDelay + 3)
        return Chart {
            ForEach(s.delayPoints) { p in delayArea(p) }
            ForEach(s.delayPoints) { p in delayLine(p) }
            ForEach(s.dropoutPoints) { p in dropoutDot(p) }
        }
        .chartYScale(domain: 0...yMax)
        .chartYAxisLabel("ms")
        .overlay {
            if s.monitoredSeconds == 0 {
                Text("No apps were being adjusted in this range")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func delayArea(_ p: LogSummary.DelayPoint) -> some ChartContent {
        let x: PlottableValue<Date> = .value("Time", p.date)
        let y: PlottableValue<Double> = .value("Delay (ms)", p.ms)
        return AreaMark(x: x, y: y)
            .interpolationMethod(.stepEnd)
            .foregroundStyle(Color.accentColor.opacity(0.15))
    }

    private func delayLine(_ p: LogSummary.DelayPoint) -> some ChartContent {
        let x: PlottableValue<Date> = .value("Time", p.date)
        let y: PlottableValue<Double> = .value("Delay (ms)", p.ms)
        return LineMark(x: x, y: y)
            .interpolationMethod(.stepEnd)
            .foregroundStyle(Color.accentColor)
    }

    private func dropoutDot(_ p: LogSummary.DelayPoint) -> some ChartContent {
        let x: PlottableValue<Date> = .value("Time", p.date)
        let y: PlottableValue<Double> = .value("Delay (ms)", p.ms)
        return PointMark(x: x, y: y)
            .foregroundStyle(Color.red)
            .symbolSize(30)
    }

    private struct BarSegment: Identifiable {
        let id: Int
        let start: Date
        let end: Date
        let low: Int
        let high: Int
        let type: String
    }

    private static let countedLabel = "Counted"
    private static let ignoredLabel = "Ignored (during a change)"

    private func barSegments(_ s: LogSummary) -> [BarSegment] {
        var out: [BarSegment] = []
        for b in s.buckets {
            if b.counted > 0 {
                out.append(BarSegment(id: out.count, start: b.start, end: b.end,
                                      low: 0, high: b.counted, type: Self.countedLabel))
            }
            if b.ignored > 0 {
                out.append(BarSegment(id: out.count, start: b.start, end: b.end,
                                      low: b.counted, high: b.counted + b.ignored, type: Self.ignoredLabel))
            }
        }
        return out
    }

    private func bar(_ seg: BarSegment) -> some ChartContent {
        let x0: PlottableValue<Date> = .value("Start", seg.start)
        let x1: PlottableValue<Date> = .value("End", seg.end)
        let y0: PlottableValue<Int> = .value("Count", seg.low)
        let y1: PlottableValue<Int> = .value("Count", seg.high)
        let kind: PlottableValue<String> = .value("Type", seg.type)
        return RectangleMark(xStart: x0, xEnd: x1, yStart: y0, yEnd: y1)
            .foregroundStyle(by: kind)
    }

    private func dropoutChart(_ s: LogSummary) -> some View {
        let segments = barSegments(s)
        let xStart: Date = s.buckets.first?.start ?? Date()
        let xEnd: Date = s.buckets.last?.end ?? Date()
        let tallest: Int = s.buckets.map { $0.counted + $0.ignored }.max() ?? 0
        let yMax: Int = max(3, tallest + 1)
        let colors: KeyValuePairs<String, Color> = [
            Self.countedLabel: Color.red,
            Self.ignoredLabel: Color.gray.opacity(0.5),
        ]
        return Chart(segments) { seg in bar(seg) }
            .chartForegroundStyleScale(colors)
            .chartXScale(domain: xStart...xEnd)
            .chartYScale(domain: 0...yMax)
            .overlay {
                if s.dropouts + s.ignored == 0 {
                    Text("No dropouts in this range")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
    }

    // MARK: Event list

    private var eventList: some View {
        let recent = Array(log.events.suffix(200).reversed())
        return Group {
            if recent.isEmpty {
                Text("Nothing logged yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(recent) { e in
                            HStack(spacing: 8) {
                                Image(systemName: e.kind.symbol)
                                    .foregroundStyle(color(for: e.kind))
                                    .frame(width: 18)
                                Text(e.kind.label)
                                if let d = e.detail {
                                    Text(d)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.tail)
                                        .textSelection(.enabled)
                                        .help(d)
                                }
                                Spacer(minLength: 8)
                                Text(e.date, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func color(for kind: LogEvent.Kind) -> Color {
        switch kind {
        case .dropout, .error: .red
        case .dropoutIgnored: .gray
        case .bufferUp: .orange
        case .bufferDown: .green
        default: .secondary
        }
    }
}

// MARK: - Pieces

private struct StatTile: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Plain-language warnings about how much (or little) the data can tell you.
private struct DataConfidenceNote: View {
    let summary: LogSummary
    let range: LogRange
    let now: Date

    var body: some View {
        let flags = buildFlags()
        if !flags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(flags, id: \.self) { flag in
                    Label(flag, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func buildFlags() -> [String] {
        var flags: [String] = []
        let rangeStart = now.addingTimeInterval(-range.duration)

        if let first = summary.logStart, first > rangeStart {
            flags.append("The log only goes back \(formatDuration(now.timeIntervalSince(first))), so most of this range has no data.")
        }

        if summary.monitoredSeconds == 0 {
            flags.append("Dropouts are only detected while an app is turned down or muted. None were in this range, so zero dropouts here doesn't mean anything yet.")
        } else if summary.monitoredSeconds < 1800 {
            flags.append("Only \(formatDuration(summary.monitoredSeconds)) of monitored time. That's too little to judge how stable audio is.")
        }

        if summary.dropouts > 0 && summary.dropouts < 5 {
            flags.append("\(summary.dropouts) dropout\(summary.dropouts == 1 ? "" : "s") is too few to show a pattern. One busy moment, like an app launching, can cause one.")
        }

        if summary.dropouts >= 5 && summary.monitoredSeconds >= 1800 {
            let perHour = Double(summary.dropouts) / (summary.monitoredSeconds / 3600)
            flags.append(String(format: "About %.1f dropouts per monitored hour. If this stays high, something on your Mac is competing for audio time.", perHour))
        }

        if summary.ignored > 0 {
            flags.append("\(summary.ignored) dropout\(summary.ignored == 1 ? " was" : "s were") ignored because \(summary.ignored == 1 ? "it" : "they") happened within 2 seconds of a tap or buffer change. Some may have been real.")
        }

        if summary.monitoredSeconds > 0 {
            flags.append("Delay shown is the buffer only; the true added delay is slightly higher. Bluetooth dropouts (e.g. AirPods interference) aren't detected.")
        }
        return flags
    }
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "\(Int(seconds)) s" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min" }
    if seconds < 86_400 { return String(format: "%.1f h", seconds / 3600) }
    return String(format: "%.1f days", seconds / 86_400)
}
