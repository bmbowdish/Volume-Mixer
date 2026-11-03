import Charts
import SwiftUI

/// Pick an output device, search AutoEq's headphone corrections, and assign one.
struct EQSettingsView: View {
    @EnvironmentObject var mixer: Mixer
    @ObservedObject private var catalog = EQCatalog.shared

    // View state without the @State attribute: newer SDKs make @State a compiler
    // macro, which a command-line build can't load. Same behavior.
    private var selectedUIDState = State<String?>(initialValue: nil)
    private var selectedUID: String? {
        get { selectedUIDState.wrappedValue }
        nonmutating set { selectedUIDState.wrappedValue = newValue }
    }
    private var queryState = State<String>(initialValue: "")
    private var query: String {
        get { queryState.wrappedValue }
        nonmutating set { queryState.wrappedValue = newValue }
    }
    private var loadingEntryState = State<EQCatalogEntry?>(initialValue: nil)
    private var loadingEntry: EQCatalogEntry? {
        get { loadingEntryState.wrappedValue }
        nonmutating set { loadingEntryState.wrappedValue = newValue }
    }
    private var fetchErrorState = State<String?>(initialValue: nil)
    private var fetchError: String? {
        get { fetchErrorState.wrappedValue }
        nonmutating set { fetchErrorState.wrappedValue = newValue }
    }

    private var deviceUID: String? { selectedUID ?? mixer.currentOutputUID }

    private var deviceName: String {
        mixer.outputDevices.first { $0.uid == deviceUID }?.name ?? "this device"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Headphone EQ").font(.title2.bold())
                    Spacer()
                    Picker("Device", selection: Binding(
                        get: { deviceUID ?? "" },
                        set: { selectedUID = $0 }
                    )) {
                        ForEach(mixer.outputDevices) { d in
                            Text(d.uid == mixer.currentOutputUID ? "\(d.name) (current)" : d.name).tag(d.uid)
                        }
                    }
                    .frame(maxWidth: 300)
                }

                if let uid = deviceUID {
                    currentProfileSection(uid)
                    EQFlags(isCurrentDevice: uid == mixer.currentOutputUID,
                            hasProfile: mixer.eqProfile(for: uid) != nil)
                    searchSection(uid)
                } else {
                    Text("No output device found.").foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .task { await catalog.loadIfNeeded() }
    }

    // MARK: Current profile

    @ViewBuilder
    private func currentProfileSection(_ uid: String) -> some View {
        GroupBox {
            if let profile = mixer.eqProfile(for: uid) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.headline)
                            Text("Measured by \(profile.source) · \(profile.filters.count) filters · preamp \(profile.preampDb, specifier: "%.1f") dB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let source = mixer.linkedSource(for: uid) {
                                Label("Shared with \(mixer.deviceName(source))", systemImage: "link")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Spacer()
                        Toggle(mixer.isEQBypassed(uid) ? "Off" : "On", isOn: Binding(
                            get: { !mixer.isEQBypassed(uid) },
                            set: { mixer.setEQBypassed(!$0, for: uid) }
                        ))
                        .toggleStyle(.switch)
                        if mixer.linkedSource(for: uid) != nil {
                            Button("Unlink") { mixer.unlinkEQ(uid) }
                                .help("Stop sharing; this device will have no EQ until you pick one")
                        } else {
                            Button("Remove", role: .destructive) { mixer.setEQ(nil, for: uid) }
                        }
                    }
                    ResponseChart(profile: profile)
                        .frame(height: 170)
                        .opacity(mixer.isEQBypassed(uid) ? 0.4 : 1)
                }
                .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No EQ on \(deviceName). Search below to add one.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let match = mixer.suggestedEQLink(for: uid) {
                        linkSuggestion(uid: uid, source: match)
                    }

                    let others = mixer.devicesWithEQ(except: uid)
                    if !others.isEmpty {
                        Menu("Use the EQ from another device…") {
                            ForEach(others, id: \.self) { source in
                                Button(mixer.deviceName(source)) { mixer.linkEQ(uid, to: source) }
                            }
                        }
                        .fixedSize()
                    }
                }
                .padding(.vertical, 6)
            }
        } label: {
            Label("EQ for \(deviceName)", systemImage: "headphones")
        }
    }

    private func linkSuggestion(uid: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This looks like the same headphones as “\(mixer.deviceName(source))” over a different connection.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Share that EQ") { mixer.linkEQ(uid, to: source) }
                    .buttonStyle(.borderedProminent)
                Text("Matched by name only. Check it's really the same pair.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Search

    @ViewBuilder
    private func searchSection(_ uid: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search headphones, e.g. AirPods Max", text: queryState.projectedValue)
                    .textFieldStyle(.roundedBorder)

                switch catalog.status {
                case .idle, .loading:
                    ProgressView("Loading headphone list…").controlSize(.small)
                case .failed(let message):
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.red)
                        Button("Retry") { Task { await catalog.loadIfNeeded() } }
                    }
                case .ready:
                    let results = catalog.search(query)
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("\(catalog.entries.count.formatted()) profiles available from AutoEq.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if results.isEmpty {
                        Text("No matches.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(results) { entry in
                                    resultRow(entry, uid: uid)
                                }
                            }
                        }
                        .frame(height: 220)
                    }
                }

                if let fetchError {
                    Text(fetchError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Find a profile", systemImage: "magnifyingglass")
        }

        Text("Profiles from [AutoEq](https://github.com/jaakkopasanen/AutoEq) by Jaakko Pasanen. Measurements by the source listed with each profile.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func resultRow(_ entry: EQCatalogEntry, uid: String) -> some View {
        let current = mixer.eqProfile(for: uid)
        let isCurrent = current?.name == entry.name && current?.source == entry.source
        return Button {
            Task { await choose(entry, uid: uid) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                    Text(entry.source).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loadingEntry == entry {
                    ProgressView().controlSize(.small)
                } else if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .disabled(loadingEntry != nil)
    }

    private func choose(_ entry: EQCatalogEntry, uid: String) async {
        loadingEntry = entry
        fetchError = nil
        defer { loadingEntry = nil }
        do {
            let profile = try await catalog.fetchProfile(entry)
            mixer.setEQ(profile, for: uid)
        } catch {
            fetchError = "Couldn't load \(entry.name): \(error.localizedDescription)"
        }
    }
}

// MARK: - Response curve

private struct ResponseChart: View {
    struct Point: Identifiable { let id: Double; let hz: Double; let db: Double }

    let profile: EQProfile

    var body: some View {
        let freqs: [Double] = (0..<120).map { i in 20 * pow(1000, Double(i) / 119) }   // 20 Hz … 20 kHz, log-spaced
        let gains: [Double] = profile.response(at: freqs)
        let points: [Point] = zip(freqs, gains).map { pair in Point(id: pair.0, hz: pair.0, db: pair.1) }
        let dbs: [Double] = points.map(\.db)
        let lo: Double = min(-6, (dbs.min() ?? 0) - 1)
        let hi: Double = max(6, (dbs.max() ?? 0) + 1)

        let ticks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]
        let xDomain: ClosedRange<Double> = 20...20_000

        Chart {
            zeroLine()
            ForEach(points) { p in curve(p) }
        }
        .chartXScale(domain: xDomain, type: .log)
        .chartYScale(domain: lo...hi)
        .chartXAxis {
            AxisMarks(values: ticks) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let hz = v.as(Double.self) {
                        Text(hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))")
                    }
                }
            }
        }
        .chartYAxisLabel("dB")
    }

    // Small typed pieces keep the Swift type checker fast.
    private func zeroLine() -> some ChartContent {
        let y: PlottableValue<Double> = .value("0 dB", 0.0)
        return RuleMark(y: y).foregroundStyle(Color.secondary.opacity(0.4))
    }

    private func curve(_ p: Point) -> some ChartContent {
        let x: PlottableValue<Double> = .value("Hz", p.hz)
        let y: PlottableValue<Double> = .value("dB", p.db)
        return LineMark(x: x, y: y)
            .interpolationMethod(.catmullRom)
            .foregroundStyle(Color.accentColor)
    }
}

// MARK: - Flags

/// Honest caveats about what these corrections can and can't do.
private struct EQFlags: View {
    let isCurrentDevice: Bool
    let hasProfile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            flag("These corrections come from measurement rigs, not your ears. Fit, head shape, and ear pads change what you hear, so treat a profile as a starting point.")
            flag("The same headphone often has several profiles from different measurers. When they disagree, that's measurement variation, not one being \"right\". Try a couple.")
            flag("AirPods (including AirPods Max) apply Apple's own adaptive EQ, which changes with fit. That makes rig-based corrections less predictable on them than on wired headphones.")
            flag("While an EQ is on, all audio on this device goes through Volume Mixer, so the added delay and dropout risk apply to everything, not just adjusted apps. Changing an app's volume briefly rebuilds the EQ path, which can cause a short blip.")
            if hasProfile && !isCurrentDevice {
                flag("This device isn't the current output. Its EQ will start when you switch to it.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func flag(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
