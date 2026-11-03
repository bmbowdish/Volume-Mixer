import AudioToolbox
import CoreAudio
import Foundation

/// Thin helpers around the Core Audio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         initial: T) -> T? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var v = initial
        let status = withUnsafeMutablePointer(to: &v) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? v : nil
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let r = ref else { return nil }
        let s = r.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let dev = value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)),
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }

    static func defaultOutputUID() -> String? {
        guard let dev = defaultOutputDevice() else { return nil }
        return string(dev, kAudioDevicePropertyDeviceUID)
    }

    // MARK: System (output device) volume

    private static let outputScope = kAudioDevicePropertyScopeOutput

    static func isSettable(_ dev: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector, scope: outputScope)
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr && settable.boolValue
    }

    /// 0...1, or nil if the device has no volume control (e.g. many HDMI outputs).
    static func outputVolume(_ dev: AudioObjectID) -> Float? {
        value(dev, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: outputScope, initial: Float32(0))
    }

    static func setOutputVolume(_ dev: AudioObjectID, _ volume: Float) {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: outputScope)
        var v = Float32(min(max(volume, 0), 1))
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func outputMuted(_ dev: AudioObjectID) -> Bool? {
        value(dev, kAudioDevicePropertyMute, scope: outputScope, initial: UInt32(0)).map { $0 != 0 }
    }

    static func setOutputMuted(_ dev: AudioObjectID, _ muted: Bool) {
        var addr = address(kAudioDevicePropertyMute, scope: outputScope)
        var v: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    static func deviceName(_ dev: AudioObjectID) -> String? {
        string(dev, kAudioObjectPropertyName)
    }

    // MARK: Output devices

    struct OutputDevice: Identifiable, Hashable {
        let id: AudioObjectID
        let uid: String
        let name: String
    }

    static func isBluetooth(_ dev: AudioObjectID) -> Bool {
        let t = value(dev, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static func sampleRate(_ dev: AudioObjectID) -> Double? {
        guard let r = value(dev, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)), r > 0 else { return nil }
        return r
    }

    /// UID prefix for the private aggregate devices AppTap creates.
    static let privateDevicePrefix = "local.volumemixer.aggregate."

    /// Every device that can play sound, excluding VolumeMixer's own private devices.
    static func outputDevices() -> [OutputDevice] {
        objectList(system, kAudioHardwarePropertyDevices).compactMap { dev in
            var addr = address(kAudioDevicePropertyStreams, scope: outputScope)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
            if (value(dev, kAudioDevicePropertyIsHidden, initial: UInt32(0)) ?? 0) != 0 { return nil }
            guard let uid = string(dev, kAudioDevicePropertyDeviceUID) else { return nil }
            // Skip our own private devices (one per tap). Other apps never see
            // them, but the app that created them does.
            if uid.hasPrefix(privateDevicePrefix) { return nil }
            return OutputDevice(id: dev, uid: uid, name: deviceName(dev) ?? uid)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Core Audio's object for a process, by PID (macOS 14.2+).
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier,
                                                &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func setDefaultOutput(_ dev: AudioObjectID) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = dev
        AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }
}

/// One process that Core Audio knows about (macOS 14.2+).
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool

    static func all() -> [AudioProcess] {
        CA.objectList(CA.system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = CA.value(id, kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
            let running = CA.value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0
            return AudioProcess(objectID: id,
                                pid: pid,
                                bundleID: CA.string(id, kAudioProcessPropertyBundleID),
                                isPlaying: running != 0)
        }
    }
}

/// Parent process ID via sysctl (used to map helper processes back to their app).
func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

struct CoreAudioError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) failed (OSStatus \(status))" }
}
