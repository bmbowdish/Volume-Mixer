import AppKit
import Security
import SwiftUI

/// Reads this app's own code signature.
enum Signature {
    /// e.g. (true, "VolumeMixer Local Signing") or (false, "ad-hoc")
    static func current() -> (stable: Bool, summary: String) {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return (false, "couldn't read the signature")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return (false, "couldn't read the signature")
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return (false, "couldn't read the signature")
        }
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certs.first {
            let name = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "a certificate"
            return (true, name)
        }
        return (false, "ad-hoc")
    }
}

/// Checklist of everything the app needs, with a fix for each problem.
struct SetupCheckView: View {
    @EnvironmentObject var mixer: Mixer
    @ObservedObject private var login = LoginItem.shared

    var body: some View {
        let signature = Signature.current()
        let inApplications = Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        let accessibility = KeyInterceptor.shared.isTrusted

        Section {
            // 1. Signature
            CheckRow(
                state: signature.stable ? .ok : .warning,
                title: "Stable signature",
                detail: signature.stable
                    ? "Signed with “\(signature.summary)”, so macOS should remember permissions across rebuilds."
                    : "This build is \(signature.summary)-signed, so macOS may forget permissions after each rebuild. Check the build output for a signing warning."
            )

            // 2. System Audio Recording
            switch mixer.captureStatus {
            case .working:
                CheckRow(state: .ok, title: "System Audio Recording",
                         detail: "Working: adjusted apps are being heard.")
            case .untested:
                CheckRow(state: .unknown, title: "System Audio Recording",
                         detail: "Not tested yet. macOS doesn't let apps ask about this directly, so it's checked by listening. Turn an app below 100% while it's playing (or turn on an EQ) and this will update within a few seconds.")
            case .likelyBlocked:
                CheckRow(state: .problem, title: "System Audio Recording",
                         detail: "Probably off: an adjusted app is playing but Volume Mixer hears only silence, so that app is muted. Allow Volume Mixer under System Audio Recording, then press Re-test.") {
                    Button("Open Settings") {
                        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
                    }
                }
            }

            // 3. Accessibility
            CheckRow(
                state: accessibility ? .ok : .optional,
                title: "Accessibility (optional)",
                detail: accessibility
                    ? "Allowed: keyboard volume keys skip the macOS popup while the panel is open."
                    : "Not allowed. Everything else works; only the keyboard volume-key feature is off."
            ) {
                if !accessibility {
                    Button("Allow…") { mixer.requestAccessibility() }
                }
            }

            // 4. Login item
            CheckRow(
                state: login.isEnabled ? .ok : (login.needsApproval ? .problem : .optional),
                title: "Open at login",
                detail: login.isEnabled
                    ? "On."
                    : login.needsApproval
                        ? "Waiting for your approval in Login Items."
                        : "Off. Turn it on below if you want it."
            ) {
                if login.needsApproval {
                    Button("Open Login Items") { login.openLoginItemsSettings() }
                }
            }

            // 5. Location
            CheckRow(
                state: inApplications ? .ok : .warning,
                title: "App location",
                detail: inApplications
                    ? "Running from ~/Applications."
                    : "Running from \(Bundle.main.bundlePath). Open at login points at a specific copy, so run the one the build script installs in ~/Applications."
            )
        } header: {
            HStack {
                Text("Setup check")
                Spacer()
                Button("Re-test") {
                    mixer.recheckCapture()
                    login.refresh()
                }
                .controlSize(.small)
            }
        } footer: {
            Text("The System Audio Recording check is inferred from behavior, not read from macOS, so it can be wrong. For example, an app playing true silence looks the same as blocked audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

private struct CheckRow<Actions: View>: View {
    enum Status { case ok, warning, problem, optional, unknown }

    let state: Status
    let title: String
    let detail: String
    let actions: Actions

    init(state: Status, title: String, detail: String, @ViewBuilder actions: () -> Actions) {
        self.state = state
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.system(size: 15))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .optional: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch state {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        case .optional, .unknown: .secondary
        }
    }
}

extension CheckRow where Actions == EmptyView {
    init(state: Status, title: String, detail: String) {
        self.init(state: state, title: title, detail: detail) { EmptyView() }
    }
}
