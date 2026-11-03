import AppKit
import AudioToolbox
import CoreAudio
import Foundation

struct AppRow: Identifiable {
    let id: String          // grouping key (usually the app's bundle ID)
    let name: String
    let icon: NSImage
}

/// Groups Core Audio processes by app, keeps per-app volume/mute settings,
/// and creates or removes taps so only adjusted apps are touched.
@MainActor
final class Mixer: ObservableObject {
    static let shared = Mixer()

    @Published private(set) var rows: [AppRow] = []
    @Published private(set) var volumes: [String: Float] = [:]
    @Published private(set) var muted: Set<String> = []
    @Published private(set) var lastError: String?

    // System output device
    @Published private(set) var outputName = "Output"
    @Published private(set) var systemVolume: Float = 1
    @Published private(set) var systemMuted = false
    @Published private(set) var systemVolumeAvailable = false
    @Published private(set) var systemMuteAvailable = false

    // MARK: Audio capture check
    //
    // macOS has no public way to ask whether System Audio Recording is allowed.
    // When it's denied, taps just receive silence. So: if a tapped source is
    // playing but its tap hears nothing for a while, permission is probably off.

    enum CaptureStatus: Equatable {
        case untested          // nothing tapped while playing yet
        case working           // a tap has received real audio this session
        case likelyBlocked     // tapped audio playing, tap hears only silence
    }

    @Published private(set) var captureStatus: CaptureStatus = .untested
    private var silentSince: [String: Date] = [:]
    private let silenceThreshold: TimeInterval = 5

    private func checkCapture() {
        let now = Date()
        var sources: [(String, AppTap, Bool)] = taps.map { key, tap in
            (key, tap, groups[key]?.isPlaying ?? false)
        }
        if let global = globalTap {
            let otherPlaying = groups.contains { key, g in taps[key] == nil && g.isPlaying }
            sources.append(("__eq__", global, otherPlaying))
        }

        var anySignal = false
        var anyLongSilence = false
        for (key, tap, playing) in sources {
            let peak = tap.takePeak()
            if peak > 0 {
                anySignal = true
                silentSince[key] = nil
            } else if playing {
                let since = silentSince[key] ?? now
                silentSince[key] = since
                if now.timeIntervalSince(since) >= silenceThreshold { anyLongSilence = true }
            } else {
                silentSince[key] = nil
            }
        }
        let active = Set(sources.map(\.0))
        silentSince = silentSince.filter { active.contains($0.key) }

        if anySignal {
            if captureStatus != .working { captureStatus = .working }
        } else if anyLongSilence, captureStatus != .working {
            captureStatus = .likelyBlocked
        }
    }

    /// Clears the result so the next playing, tapped app re-tests it.
    func recheckCapture() {
        captureStatus = .untested
        silentSince.removeAll()
    }

    /// Set when Bluetooth output has dropped to headset mode (mic in use).
    @Published private(set) var headsetModeRate: Double?

    // Output devices
    @Published private(set) var outputDevices: [CA.OutputDevice] = []
    @Published private(set) var currentOutputUID: String?
    /// Output devices hidden from the menu (e.g. monitors without speakers).
    @Published private(set) var hiddenDevices: Set<String> = []

    /// Devices to show in the output menu. The current output always shows,
    /// even if hidden, so you can see where audio is going.
    var visibleOutputDevices: [CA.OutputDevice] {
        outputDevices.filter { !hiddenDevices.contains($0.uid) || $0.uid == currentOutputUID }
    }

    func setHidden(_ hidden: Bool, deviceUID: String) {
        if hidden { hiddenDevices.insert(deviceUID) } else { hiddenDevices.remove(deviceUID) }
        save()
    }

    // Per-device EQ, keyed by device UID
    @Published private(set) var eqProfiles: [String: EQProfile] = [:]
    @Published private(set) var eqBypassed: Set<String> = []
    /// Device UID → the device UID whose EQ it shares (e.g. USB AirPods → Bluetooth AirPods).
    @Published private(set) var eqLinks: [String: String] = [:]
    /// Names of every output device seen, so links work while one is disconnected.
    @Published private(set) var knownDeviceNames: [String: String] = [:]
    @Published private(set) var eqActive = false

    // Keyboard volume keys (hide the macOS popup while the panel is open)
    @Published private(set) var needsAccessibility = false

    private var panelOpen = false

    // MARK: Adaptive buffer
    //
    // Start with a small buffer (low delay). On a dropout, step up one size.
    // After 2 clean minutes, step back down one size. Overloads right after a
    // tap is created or resized are ignored, since reconfiguring itself can
    // trigger one and we don't want that to snowball.

    private let bufferLevels: [UInt32] = [256, 512, 1024]   // ≈ 5 / 11 / 21 ms at 48 kHz
    private var bufferLevel = 0
    private var lastReconfigure = Date.distantPast
    private var lastTrouble = Date.distantPast
    private let settleTime: TimeInterval = 2
    private let cleanTimeBeforeShrinking: TimeInterval = 120

    @Published private(set) var dropoutCount = 0
    @Published private(set) var bufferDelayMs: Double?
    @Published private(set) var isTapping = false

    func handleOverload() {
        let now = Date()
        guard now.timeIntervalSince(lastReconfigure) > settleTime else {
            log(.dropoutIgnored)
            return
        }
        dropoutCount += 1
        lastTrouble = now
        log(.dropout)
        if bufferLevel < bufferLevels.count - 1 {
            let from = bufferLevels[bufferLevel]
            bufferLevel += 1
            applyBufferSize()
            log(.bufferUp, "\(from) → \(bufferLevels[bufferLevel]) frames; \(allTaps.first?.bufferReport ?? "")")
        }
    }

    private func maybeShrinkBuffer() {
        let now = Date()
        guard bufferLevel > 0, isTapping,
              now.timeIntervalSince(lastTrouble) > cleanTimeBeforeShrinking,
              now.timeIntervalSince(lastReconfigure) > cleanTimeBeforeShrinking else { return }
        let from = bufferLevels[bufferLevel]
        bufferLevel -= 1
        applyBufferSize()
        log(.bufferDown, "\(from) → \(bufferLevels[bufferLevel]) frames after 2 clean minutes; \(allTaps.first?.bufferReport ?? "")")
    }

    /// Records an event with the added delay currently in effect.
    private func log(_ kind: LogEvent.Kind, _ detail: String? = nil) {
        EventLog.shared.add(kind, detail: detail, delayMs: isTapping ? (bufferDelayMs ?? 0) : 0)
    }

    private func applyBufferSize() {
        lastReconfigure = Date()
        for tap in allTaps { tap.setBufferFrames(bufferLevels[bufferLevel]) }
        updateDelayEstimate()
    }

    private var allTaps: [AppTap] { Array(taps.values) + (globalTap.map { [$0] } ?? []) }

    private func updateDelayEstimate() {
        isTapping = !allTaps.isEmpty
        eqActive = globalTap != nil
        bufferDelayMs = allTaps.lazy.compactMap { $0.bufferMilliseconds }.first
    }

    func setPanelOpen(_ open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        let keys = KeyInterceptor.shared
        if open {
            keys.start()
            refresh()
        } else {
            keys.stop()
        }
        needsAccessibility = !keys.isTrusted
    }

    func requestAccessibility() {
        KeyInterceptor.shared.requestPermission()
    }

    private struct Group {
        let key: String
        let name: String
        let icon: NSImage
        var processIDs: Set<AudioObjectID> = []
        var isPlaying = false
    }

    private var groups: [String: Group] = [:]
    private var taps: [String: AppTap] = [:]
    private var failed: [String: Set<AudioObjectID>] = [:]
    private var lastHeard: [String: Date] = [:]
    private var outputUID: String?
    private var timer: Timer?

    private let volumesKey = "volumes"
    private let mutedKey = "muted"
    private let eqKey = "eqProfiles"
    private let eqBypassKey = "eqBypassed"
    private let eqLinksKey = "eqLinks"
    private let deviceNamesKey = "knownDeviceNames"
    private let hiddenDevicesKey = "hiddenDevices"

    private var globalTap: AppTap?
    private var failedGlobal: AppTap.Target?
    private var ownProcessIDs: Set<AudioObjectID> = []

    // MARK: Lifecycle

    func start() {
        let defaults = UserDefaults.standard
        if let saved = defaults.dictionary(forKey: volumesKey) as? [String: Double] {
            volumes = saved.mapValues { Float($0) }
        }
        muted = Set(defaults.stringArray(forKey: mutedKey) ?? [])
        if let data = defaults.data(forKey: eqKey),
           let saved = try? JSONDecoder().decode([String: EQProfile].self, from: data) {
            eqProfiles = saved
        }
        eqBypassed = Set(defaults.stringArray(forKey: eqBypassKey) ?? [])
        eqLinks = (defaults.dictionary(forKey: eqLinksKey) as? [String: String]) ?? [:]
        knownDeviceNames = (defaults.dictionary(forKey: deviceNamesKey) as? [String: String]) ?? [:]
        hiddenDevices = Set(defaults.stringArray(forKey: hiddenDevicesKey) ?? [])

        log(.launched)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in Mixer.shared.refresh() }
        }
    }

    func shutdown() {
        timer?.invalidate()
        KeyInterceptor.shared.stop()
        for tap in allTaps { tap.stop() }
        taps.removeAll()
        globalTap = nil
        updateDelayEstimate()
        log(.quit)
    }

    // MARK: Settings

    func volume(_ key: String) -> Float { volumes[key] ?? 1.0 }
    func isMuted(_ key: String) -> Bool { muted.contains(key) }

    func setVolume(_ key: String, _ value: Float) {
        let v = min(max(value, 0), 1)
        if v >= 0.995 { volumes.removeValue(forKey: key) } else { volumes[key] = v }
        save()
        reconcile()
    }

    func toggleMute(_ key: String) {
        if muted.contains(key) { muted.remove(key) } else { muted.insert(key) }
        save()
        reconcile()
    }

    func resetAll() {
        volumes.removeAll()
        muted.removeAll()
        save()
        reconcile()
    }

    func setSystemVolume(_ value: Float) {
        guard let dev = CA.defaultOutputDevice() else { return }
        CA.setOutputVolume(dev, value)
        systemVolume = min(max(value, 0), 1)
        // Dragging the slider up from zero should unmute, like the macOS menu does.
        if systemMuted, value > 0, systemMuteAvailable {
            CA.setOutputMuted(dev, false)
            systemMuted = false
        }
    }

    func toggleSystemMute() {
        guard let dev = CA.defaultOutputDevice(), systemMuteAvailable else { return }
        CA.setOutputMuted(dev, !systemMuted)
        systemMuted.toggle()
    }

    private func refreshSystemVolume() {
        guard let dev = CA.defaultOutputDevice() else {
            systemVolumeAvailable = false
            systemMuteAvailable = false
            return
        }
        outputName = CA.deviceName(dev) ?? "Output"
        systemVolumeAvailable = CA.isSettable(dev, kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        systemMuteAvailable = CA.isSettable(dev, kAudioDevicePropertyMute)
        if let v = CA.outputVolume(dev) { systemVolume = v }
        systemMuted = CA.outputMuted(dev) ?? false

        // Bluetooth headphones normally run at 44.1/48 kHz; below that means the
        // two-way headset mode used while their mic is on.
        let rate = CA.sampleRate(dev)
        let lowRate: Double? = (CA.isBluetooth(dev) && (rate ?? 48_000) < 44_000) ? rate : nil
        if lowRate != headsetModeRate { headsetModeRate = lowRate }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(volumes.mapValues { Double($0) }, forKey: volumesKey)
        defaults.set(Array(muted), forKey: mutedKey)
        if let data = try? JSONEncoder().encode(eqProfiles) { defaults.set(data, forKey: eqKey) }
        defaults.set(Array(eqBypassed), forKey: eqBypassKey)
        defaults.set(eqLinks, forKey: eqLinksKey)
        defaults.set(knownDeviceNames, forKey: deviceNamesKey)
        defaults.set(Array(hiddenDevices), forKey: hiddenDevicesKey)
    }

    // MARK: Output devices

    func setOutput(_ device: CA.OutputDevice) {
        CA.setDefaultOutput(device.id)
        refresh()
    }

    // MARK: Per-device EQ

    /// The device's own EQ, or the EQ of the device it's linked to.
    func eqProfile(for deviceUID: String) -> EQProfile? {
        if let own = eqProfiles[deviceUID] { return own }
        if let source = eqLinks[deviceUID] { return eqProfiles[source] }
        return nil
    }
    func isEQBypassed(_ deviceUID: String) -> Bool { eqBypassed.contains(deviceUID) }
    func linkedSource(for deviceUID: String) -> String? {
        eqProfiles[deviceUID] == nil ? eqLinks[deviceUID] : nil
    }
    func deviceName(_ uid: String) -> String { knownDeviceNames[uid] ?? "another device" }

    /// Devices that have their own EQ, other than this one (for "use EQ from…").
    func devicesWithEQ(except uid: String) -> [String] {
        eqProfiles.keys.filter { $0 != uid }.sorted { deviceName($0) < deviceName($1) }
    }

    /// Another device with an EQ whose name looks like the same headphones,
    /// e.g. "Alex’s AirPods Max" and "AirPods Max USB Audio". Name-based guess,
    /// so the UI asks before linking.
    func suggestedEQLink(for uid: String) -> String? {
        guard eqProfile(for: uid) == nil, let name = knownDeviceNames[uid] else { return nil }
        let key = Self.headphoneKey(name)
        guard key.count >= 4 else { return nil }   // too generic to match on
        return devicesWithEQ(except: uid).first { Self.headphoneKey(deviceName($0)) == key }
    }

    /// "Alex’s AirPods Max" → "airpods max"; "AirPods Max USB Audio" → "airpods max".
    nonisolated static func headphoneKey(_ name: String) -> String {
        var n = name.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
        if let r = n.range(of: "'s ") { n = String(n[r.upperBound...]) }   // drop "Owner's "
        for suffix in [" usb audio", " usb", " (usb)", " audio", " stereo", " hands-free"] where n.hasSuffix(suffix) {
            n = String(n.dropLast(suffix.count))
        }
        return n.trimmingCharacters(in: .whitespaces)
    }

    func linkEQ(_ uid: String, to source: String) {
        eqLinks[uid] = source
        eqProfiles.removeValue(forKey: uid)
        failedGlobal = nil
        save()
        reconcile()
    }

    func unlinkEQ(_ uid: String) {
        eqLinks.removeValue(forKey: uid)
        failedGlobal = nil
        save()
        reconcile()
    }

    func setEQ(_ profile: EQProfile?, for deviceUID: String) {
        if let profile { eqProfiles[deviceUID] = profile } else { eqProfiles.removeValue(forKey: deviceUID) }
        eqLinks.removeValue(forKey: deviceUID)
        // Removing a device's EQ also removes links that pointed at it.
        if profile == nil { eqLinks = eqLinks.filter { $0.value != deviceUID } }
        eqBypassed.remove(deviceUID)
        failedGlobal = nil
        save()
        reconcile()
    }

    func setEQBypassed(_ bypassed: Bool, for deviceUID: String) {
        if bypassed { eqBypassed.insert(deviceUID) } else { eqBypassed.remove(deviceUID) }
        failedGlobal = nil
        save()
        reconcile()
    }

    /// The EQ that should be running right now (for the current output, unless bypassed).
    private var currentEQ: EQProfile? {
        guard let uid = outputUID, !eqBypassed.contains(uid) else { return nil }
        return eqProfile(for: uid)
    }

    private func needsTap(_ key: String) -> Bool { muted.contains(key) || volumes[key] != nil }
    private func gain(_ key: String) -> Float { muted.contains(key) ? 0 : volume(key) }

    // MARK: Polling

    func refresh() {
        refreshSystemVolume()
        maybeShrinkBuffer()
        if panelOpen {
            // Picks up Accessibility permission granted while the panel is open.
            let keys = KeyInterceptor.shared
            if !keys.isActive { keys.start() }
            needsAccessibility = !keys.isTrusted
        }
        outputDevices = CA.outputDevices()
        var namesChanged = false
        for d in outputDevices where knownDeviceNames[d.uid] != d.name {
            knownDeviceNames[d.uid] = d.name
            namesChanged = true
        }
        if namesChanged { save() }
        let currentOutput = CA.defaultOutputUID()
        currentOutputUID = currentOutput
        if currentOutput != outputUID {
            // Output device changed (e.g. headphones plugged in): rebuild every tap.
            let hadOutput = outputUID != nil
            for tap in allTaps { tap.stop() }
            taps.removeAll()
            globalTap = nil
            failedGlobal = nil
            tapNames.removeAll()
            failed.removeAll()
            outputUID = currentOutput
            updateDelayEstimate()
            if hadOutput {
                let name = CA.defaultOutputDevice().flatMap(CA.deviceName) ?? "unknown device"
                log(.outputChanged, name)
            }
        }

        let myPID = getpid()
        let processes = AudioProcess.all()
        ownProcessIDs = Set(processes.filter { $0.pid == myPID }.map(\.objectID))
        if ownProcessIDs.isEmpty, let me = CA.processObject(for: myPID) { ownProcessIDs = [me] }
        var newGroups: [String: Group] = [:]
        for proc in processes where proc.pid != myPID {
            let (key, name, icon) = identify(proc)
            var g = newGroups[key] ?? Group(key: key, name: name, icon: icon)
            g.processIDs.insert(proc.objectID)
            g.isPlaying = g.isPlaying || proc.isPlaying
            newGroups[key] = g
        }
        groups = newGroups

        let now = Date()
        for g in groups.values where g.isPlaying { lastHeard[g.key] = now }

        // Show apps playing now or in the last 30 s, plus any app you've adjusted.
        rows = groups.values
            .filter { g in
                if needsTap(g.key) { return true }
                if let t = lastHeard[g.key], now.timeIntervalSince(t) < 30 { return true }
                return false
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { AppRow(id: $0.key, name: $0.name, icon: $0.icon) }

        reconcile()
        checkCapture()
    }

    private var tapNames: [String: String] = [:]

    private func reconcile() {
        guard let uid = outputUID else { return }
        var pending: [(LogEvent.Kind, String)] = []

        for (key, group) in groups where needsTap(key) && !group.processIDs.isEmpty {
            if let tap = taps[key], tap.processIDs == group.processIDs, tap.outputUID == uid,
               tap.eqProfile == currentEQ {
                tap.setGain(gain(key))
                continue
            }
            if failed[key] == group.processIDs { continue }   // don't retry every second
            let isRebuild = taps[key] != nil                    // e.g. a new Chrome helper appeared
            taps[key]?.stop()
            taps[key] = nil
            do {
                taps[key] = try AppTap(target: .processes(group.processIDs), outputUID: uid,
                                       gain: gain(key), eq: currentEQ,
                                       bufferFrames: bufferLevels[bufferLevel],
                                       onOverload: { Mixer.shared.handleOverload() })
                lastReconfigure = Date()
                failed[key] = nil
                lastError = nil
                tapNames[key] = group.name
                if !isRebuild { pending.append((.tapStarted, "\(group.name): \(taps[key]?.bufferReport ?? "")")) }
            } catch {
                failed[key] = group.processIDs
                lastError = "\(group.name): \(error.localizedDescription)"
                pending.append((.error, lastError ?? group.name))
            }
        }

        for key in Array(taps.keys) where !(groups[key] != nil && needsTap(key)) {
            taps[key]?.stop()
            taps.removeValue(forKey: key)
            pending.append((.tapStopped, tapNames.removeValue(forKey: key) ?? key))
        }

        reconcileGlobalTap(outputUID: uid, pending: &pending)
        updateDelayEstimate()
        for (kind, detail) in pending { log(kind, detail) }
    }

    /// With an EQ on, every other sound on the Mac goes through one shared
    /// tap. It must exclude apps that already have their own tap (and this
    /// app), or they'd be heard twice.
    private func reconcileGlobalTap(outputUID uid: String, pending: inout [(LogEvent.Kind, String)]) {
        guard let eq = currentEQ else {
            if let old = globalTap {
                old.stop()
                globalTap = nil
                pending.append((.tapStopped, "EQ: \(old.eqProfile?.displayName ?? "profile")"))
            }
            return
        }

        // Safety: if this app isn't excluded, the EQ tap would capture its own
        // playback and loop it back forever. Wait until we can identify ourselves.
        guard !ownProcessIDs.isEmpty else {
            lastError = "EQ: waiting for macOS to register this app's audio. Try again in a moment."
            return
        }

        var excluded = ownProcessIDs
        for key in taps.keys { excluded.formUnion(groups[key]?.processIDs ?? []) }
        let target = AppTap.Target.everythingExcept(excluded)

        if let tap = globalTap, tap.target == target, tap.outputUID == uid, tap.eqProfile == eq { return }
        if failedGlobal == target { return }

        let wasRunning = globalTap != nil
        globalTap?.stop()
        globalTap = nil
        do {
            globalTap = try AppTap(target: target, outputUID: uid, gain: 1, eq: eq,
                                   bufferFrames: bufferLevels[bufferLevel],
                                   onOverload: { Mixer.shared.handleOverload() })
            lastReconfigure = Date()
            failedGlobal = nil
            if !wasRunning { pending.append((.tapStarted, "EQ: \(eq.displayName): \(globalTap?.bufferReport ?? "")")) }
        } catch {
            failedGlobal = target
            lastError = "EQ: \(error.localizedDescription)"
            pending.append((.error, lastError ?? "EQ"))
        }
    }

    // MARK: App identification

    private var iconCache: [String: NSImage] = [:]

    /// Maps an audio process to the app that owns it. Helper processes
    /// (e.g. Chrome Helper) are walked up to their parent app.
    private func identify(_ proc: AudioProcess) -> (String, String, NSImage) {
        // Background system processes that make sound, shown with friendly names.
        if let pname = processName(proc.pid), let known = Self.systemProcesses[pname] {
            let icon = NSImage(systemSymbolName: known.symbol, accessibilityDescription: nil) ?? genericIcon
            return ("system.\(pname)", known.name, icon)
        }

        if let bid = proc.bundleID, bid.hasPrefix("com.apple.WebKit") {
            return ("com.apple.Safari", "Safari / WebKit", icon(forBundleID: "com.apple.Safari"))
        }

        if let app = owningApp(proc.pid) {
            let key = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
            let name = app.localizedName ?? key
            return (key, name, app.icon ?? genericIcon)
        }

        let key = proc.bundleID ?? "pid.\(proc.pid)"
        return (key, processName(proc.pid) ?? key, proc.bundleID.map(icon(forBundleID:)) ?? genericIcon)
    }

    private static let systemProcesses: [String: (name: String, symbol: String)] = [
        "systemsoundserverd": ("System sounds (alerts)", "bell.fill"),
        "SpeechSynthesisServerXPC": ("Spoken content", "text.bubble.fill"),
        "com.apple.speech.speechsynthesisd": ("Spoken content", "text.bubble.fill"),
        "NotificationCenter": ("Notifications", "bell.badge.fill"),
        "AirPlayXPCHelper": ("AirPlay", "airplayaudio"),
    ]

    private func owningApp(_ pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<6 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentPID(of: current), parent > 1 else { break }
            current = parent
        }
        return NSRunningApplication(processIdentifier: pid)
    }

    private func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let len = proc_name(pid, &buf, UInt32(buf.count))
        return len > 0 ? String(cString: buf) : nil
    }

    private func icon(forBundleID bid: String) -> NSImage {
        if let cached = iconCache[bid] { return cached }
        var img = genericIcon
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        }
        iconCache[bid] = img
        return img
    }

    private var genericIcon: NSImage {
        NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}
