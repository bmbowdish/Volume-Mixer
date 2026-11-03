import AppKit
import SwiftUI

@main
struct VolumeMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var mixer = Mixer.shared

    var body: some Scene {
        MenuBarExtra("Volume Mixer", systemImage: "slider.vertical.3") {
            MixerView()
                .environmentObject(mixer)
        }
        .menuBarExtraStyle(.window)

        Window("Volume Mixer Settings", id: "settings") {
            SettingsView()
                .environmentObject(mixer)
        }
        .defaultSize(width: 620, height: 760)
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Mixer.shared.start()
            LoginItem.shared.setUpOnFirstLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Mixer.shared.shutdown() }
    }
}

struct MixerView: View {
    @EnvironmentObject var mixer: Mixer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volume Mixer").font(.headline)

            if let error = mixer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SystemVolumeView()

            if let rate = mixer.headsetModeRate {
                HeadsetModeNotice(rate: rate)
            }

            if mixer.captureStatus == .likelyBlocked {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("Adjusted apps are silent. System Audio Recording permission is probably off.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Fix…") {
                        openWindow(id: "settings")
                        NSApp.activate()
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if mixer.needsAccessibility {
                HStack(alignment: .top, spacing: 6) {
                    Text("Allow Accessibility to hide the macOS volume popup for keyboard keys while this is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Allow") { mixer.requestAccessibility() }
                        .controlSize(.small)
                }
            }

            Divider()

            Text("Apps")
                .font(.caption)
                .foregroundStyle(.secondary)

            if mixer.rows.isEmpty {
                Text("No apps are playing audio right now.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(mixer.rows) { row in
                    AppRowView(row: row)
                }
            }

            Divider()

            HStack {
                Button("Reset all") { mixer.resetAll() }
                Spacer()
                Button {
                    openWindow(id: "settings")
                    NSApp.activate()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings & audio health log")
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
        .background(PanelVisibilityObserver { open in mixer.setPanelOpen(open) })
    }

}

/// Reports whether the menu-bar panel is actually on screen, so volume keys
/// are only intercepted while you can see the mixer.
struct PanelVisibilityObserver: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            tokens.forEach { center.removeObserver($0) }
            tokens = []

            guard let window else { onChange?(false); return }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.willCloseNotification,
            ]
            for name in names {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.report(closing: closing) }
                })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard let window else { onChange?(false); return }
            onChange?(!closing && window.isVisible && window.occlusionState.contains(.visible))
        }

        deinit {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

struct SystemVolumeView: View {
    @EnvironmentObject var mixer: Mixer

    var body: some View {
        let muted = mixer.systemMuted
        let volume = mixer.systemVolume

        HStack(spacing: 10) {
            Image(systemName: "hifispeaker.fill")
                .font(.system(size: 16))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Menu {
                    // An inline picker gives native menu checkmarks on the current device.
                    Picker("Output", selection: Binding(
                        get: { mixer.currentOutputUID ?? "" },
                        set: { uid in
                            if let device = mixer.outputDevices.first(where: { $0.uid == uid }) {
                                mixer.setOutput(device)
                            }
                        }
                    )) {
                        ForEach(mixer.visibleOutputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text("System · \(mixer.outputName)")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
                // Let long device names truncate instead of widening the panel.
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Choose output device: \(mixer.outputName)")
                if mixer.eqActive, let uid = mixer.currentOutputUID, let eq = mixer.eqProfile(for: uid) {
                    Text("EQ: \(eq.name)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if mixer.systemVolumeAvailable {
                    Slider(
                        value: Binding(
                            get: { Double(volume) },
                            set: { mixer.setSystemVolume(Float($0)) }
                        ),
                        in: 0...1
                    )
                } else {
                    Text("This device controls its own volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(mixer.systemVolumeAvailable ? "\(Int((volume * 100).rounded()))%" : "")
                .monospacedDigit()
                .foregroundStyle(muted ? .secondary : .primary)
                .frame(width: 40, alignment: .trailing)

            Button {
                mixer.toggleSystemMute()
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(muted ? .red : .primary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!mixer.systemMuteAvailable)
            .help(muted ? "Unmute" : "Mute")
        }
    }
}

/// Explains why Bluetooth audio sounds worse while its mic is in use.
struct HeadsetModeNotice: View {
    let rate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Headset mode (\(Int(rate / 1000)) kHz): the mic on these headphones is in use, so audio is lower quality and delay is about twice as long.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "mic.fill")
            }
            .font(.caption)
            HStack {
                Text("Fix: choose a different microphone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sound Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AppRowView: View {
    @EnvironmentObject var mixer: Mixer
    let row: AppRow

    var body: some View {
        let muted = mixer.isMuted(row.id)
        let volume = mixer.volume(row.id)

        HStack(spacing: 10) {
            Image(nsImage: row.icon)
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Slider(
                    value: Binding(
                        get: { Double(volume) },
                        set: { mixer.setVolume(row.id, Float($0)) }
                    ),
                    in: 0...1
                )
                .disabled(muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(Int((volume * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(muted ? .secondary : .primary)
                .frame(width: 40, alignment: .trailing)

            Button {
                mixer.toggleMute(row.id)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(muted ? .red : .primary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(muted ? "Unmute" : "Mute")
        }
    }
}
