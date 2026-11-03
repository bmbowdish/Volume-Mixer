import AppKit
import ApplicationServices
import CoreGraphics

/// While the mixer panel is open, catches the keyboard volume keys before
/// macOS sees them and changes the volume ourselves, so the macOS volume
/// popup doesn't appear. Only installed while the panel is visible; removed
/// the moment it closes. Needs Accessibility permission.
///
/// Note: AirPods / Bluetooth volume changes don't come through as key
/// presses, so they can't be caught this way.
@MainActor
final class KeyInterceptor {
    static let shared = KeyInterceptor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isTrusted: Bool { AXIsProcessTrusted() }
    var isActive: Bool { tap != nil }

    /// Shows the macOS "allow Accessibility" prompt and adds the app to the list.
    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let systemDefinedMask = CGEventMask(1 << 14)   // NX_SYSDEFINED: media keys
        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefinedMask,
            callback: volumeKeyCallback,
            userInfo: nil
        ) else { return }

        tap = newTap
        let src = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
    }

    func stop() {
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        if let s = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
        }
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
    }
}

// Media-key codes (from IOKit's ev_keymap.h)
private let keySoundUp: Int32 = 0
private let keySoundDown: Int32 = 1
private let keyMute: Int32 = 7

/// Runs on the main thread (the tap's run-loop source is on the main run loop).
private let volumeKeyCallback: CGEventTapCallBack = { _, type, event, _ in
    // macOS disables slow taps; turn it straight back on.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { KeyInterceptor.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }

    guard type.rawValue == 14,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.type == .systemDefined,
          nsEvent.subtype.rawValue == 8          // aux control buttons (media keys)
    else { return Unmanaged.passUnretained(event) }

    let data = nsEvent.data1
    let keyCode = Int32((data & 0xFFFF_0000) >> 16)
    let isKeyDown = ((data & 0xFF00) >> 8) == 0x0A
    let fine = nsEvent.modifierFlags.contains([.shift, .option])

    let consumed = MainActor.assumeIsolated {
        Mixer.shared.handleVolumeKey(keyCode, isKeyDown: isKeyDown, fine: fine)
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}

extension Mixer {
    /// Returns true if the key was handled (and should be hidden from macOS).
    func handleVolumeKey(_ code: Int32, isKeyDown: Bool, fine: Bool) -> Bool {
        switch code {
        case keySoundUp, keySoundDown:
            guard systemVolumeAvailable else { return false }   // let macOS handle it
            if isKeyDown {
                // Same steps as macOS: 16 notches, or 64 with Shift+Option.
                let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0
                let direction: Float = code == keySoundUp ? 1 : -1
                let snapped = ((systemVolume / step).rounded() + direction) * step
                setSystemVolume(min(max(snapped, 0), 1))
            }
            return true
        case keyMute:
            guard systemMuteAvailable else { return false }
            if isKeyDown { toggleSystemMute() }
            return true
        default:
            return false
        }
    }
}
