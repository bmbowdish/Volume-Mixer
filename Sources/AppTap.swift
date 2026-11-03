import CoreAudio
import Foundation

/// Taps audio (muting the original), applies gain and optional EQ, and plays
/// it back out of the current output device. Uses the macOS 14.2+ process-tap
/// API, so no system driver is installed. Everything is private to this
/// process: if VolumeMixer quits or crashes, macOS removes the tap and audio
/// goes back to normal.
///
/// Two kinds of target:
/// - `.processes`: one app (per-app volume).
/// - `.everythingExcept`: all other audio on the Mac, used for device EQ so
///   apps at 100% still get EQ'd. It excludes apps that have their own tap
///   (and VolumeMixer itself), otherwise they'd be heard twice.
final class AppTap {
    enum Target: Hashable {
        case processes(Set<AudioObjectID>)
        case everythingExcept(Set<AudioObjectID>)
    }

    let target: Target
    let outputUID: String
    let eqProfile: EQProfile?

    var processIDs: Set<AudioObjectID> {
        if case .processes(let ids) = target { return ids }
        return []
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let context: RenderContext
    private var overloadListener: AudioObjectPropertyListenerBlock?

    /// - bufferFrames: requested I/O buffer size (smaller = less delay, more crackle risk).
    /// - eq: parametric EQ to apply, or nil for none.
    /// - onOverload: called on the main thread when Core Audio reports a missed deadline (a dropout).
    init(target: Target, outputUID: String, gain: Float, eq: EQProfile?,
         bufferFrames: UInt32, onOverload: @escaping @MainActor () -> Void) throws {
        self.target = target
        self.outputUID = outputUID
        self.eqProfile = eq
        context = RenderContext(gain: gain)

        // 1. Create the tap; the tapped audio is muted at its normal output.
        let desc: CATapDescription
        switch target {
        case .processes(let ids):
            desc = CATapDescription(stereoMixdownOfProcesses: ids.sorted())
        case .everythingExcept(let ids):
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: ids.sorted())
        }
        desc.uuid = UUID()
        desc.name = "VolumeMixer tap"
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { stop(); throw CoreAudioError(step: "Creating audio tap", status: status) }

        // Work out how many input buffers the tap contributes.
        if let fmt = CA.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) {
            let nonInterleaved = (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            context.tapBuffers = nonInterleaved ? max(Int(fmt.mChannelsPerFrame), 1) : 1
        }

        // 2. Private aggregate device: real output device + the tap as input.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer",
            kAudioAggregateDeviceUIDKey: CA.privateDevicePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw CoreAudioError(step: "Creating aggregate device", status: status) }

        setBufferFrames(bufferFrames)

        // EQ coefficients depend on the sample rate the device actually runs at.
        if let eq {
            let rate = CA.value(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
            context.eq = EQRuntime(profile: eq, sampleRate: rate > 0 ? rate : 48_000)
        }

        // Dropout detection: Core Audio flips this property when a cycle misses its deadline.
        var overloadAddr = CA.address(kAudioDeviceProcessorOverload)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onOverload() }
        }
        if AudioObjectAddPropertyListenerBlock(aggregateID, &overloadAddr, DispatchQueue.main, listener) == noErr {
            overloadListener = listener
        }

        // 3. Real-time callback.
        let ctx = context
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            render(ctx, input: input, output: output)
        }
        guard status == noErr else { stop(); throw CoreAudioError(step: "Creating audio callback", status: status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { stop(); throw CoreAudioError(step: "Starting audio", status: status) }
    }

    func setGain(_ gain: Float) {
        context.gain.pointee = gain
    }

    /// Loudest sample heard since the last call, then resets. 0 means pure silence.
    func takePeak() -> Float {
        let p = context.peak.pointee
        context.peak.pointee = 0
        return p
    }

    /// Requests a buffer size, clamped to what the device allows.
    func setBufferFrames(_ frames: UInt32) {
        guard aggregateID != kAudioObjectUnknown else { return }
        lastRequestedFrames = frames
        var target = frames
        if let range = CA.value(aggregateID, kAudioDevicePropertyBufferFrameSizeRange, initial: AudioValueRange()),
           range.mMaximum > 0 {
            deviceFrameRange = range
            target = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
        }
        var addr = CA.address(kAudioDevicePropertyBufferFrameSize)
        lastSetStatus = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil,
                                                   UInt32(MemoryLayout<UInt32>.size), &target)
    }

    private var lastRequestedFrames: UInt32 = 0
    private var deviceFrameRange: AudioValueRange?
    private var lastSetStatus: OSStatus = noErr

    /// e.g. "requested 256, running 512 frames (device allows 512–4096) at 48 kHz"
    var bufferReport: String {
        let actual = CA.value(aggregateID, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)) ?? 0
        let rate = CA.value(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
        var text = "requested \(lastRequestedFrames), running \(actual) frames"
        if let r = deviceFrameRange {
            text += " (device allows \(Int(r.mMinimum))–\(Int(r.mMaximum)))"
        } else {
            text += " (device range unknown)"
        }
        if rate > 0 { text += String(format: " at %.1f kHz", rate / 1000) }
        if lastSetStatus != noErr { text += ", macOS refused the change (OSStatus \(lastSetStatus))" }
        return text
    }

    /// Current buffer length in milliseconds (the main part of the added delay).
    var bufferMilliseconds: Double? {
        guard aggregateID != kAudioObjectUnknown,
              let frames = CA.value(aggregateID, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)),
              let rate = CA.value(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)),
              rate > 0 else { return nil }
        return Double(frames) / rate * 1000
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let listener = overloadListener {
            var addr = CA.address(kAudioDeviceProcessorOverload)
            AudioObjectRemovePropertyListenerBlock(aggregateID, &addr, DispatchQueue.main, listener)
        }
        overloadListener = nil
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        stop()
    }
}

/// Memory the audio thread uses, allocated up front so it never allocates.
final class RenderContext {
    static let maxFrames = 8192
    static let maxChannels = EQRuntime.maxChannels

    let gain: UnsafeMutablePointer<Float>
    /// Loudest input sample since the main thread last read it (before gain),
    /// used to tell whether the tap receives real audio or only silence.
    let peak: UnsafeMutablePointer<Float>
    let scratch: UnsafeMutablePointer<Float>
    var eq: EQRuntime?
    var tapBuffers = 1

    init(gain: Float) {
        self.gain = .allocate(capacity: 1)
        self.gain.initialize(to: gain)
        peak = .allocate(capacity: 1)
        peak.initialize(to: 0)
        let count = RenderContext.maxFrames * RenderContext.maxChannels
        scratch = .allocate(capacity: count)
        scratch.initialize(repeating: 0, count: count)
    }

    deinit {
        gain.deallocate()
        peak.deallocate()
        scratch.deallocate()
    }
}

/// Runs on Core Audio's real-time thread: no allocation, no locks.
/// 1. Copy the tap's channels into scratch (the tap's buffers are the last
///    `tapBuffers` input buffers; any mic on the output device comes first
///    and is ignored).
/// 2. EQ each channel once, then apply gain and the EQ's preamp.
/// 3. Spread those channels across however many outputs the device has.
private func render(_ ctx: RenderContext,
                    input: UnsafePointer<AudioBufferList>,
                    output: UnsafeMutablePointer<AudioBufferList>) {
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outList = UnsafeMutableAudioBufferListPointer(output)
    let firstTap = max(0, inList.count - ctx.tapBuffers)
    let maxFrames = RenderContext.maxFrames
    let floatSize = MemoryLayout<Float>.size

    // How many frames the tap delivered this cycle.
    var frames = maxFrames
    var sawInput = false
    if firstTap < inList.count {
        for ii in firstTap..<inList.count {
            let ic = Int(inList[ii].mNumberChannels)
            guard ic > 0, inList[ii].mData != nil else { continue }
            frames = min(frames, Int(inList[ii].mDataByteSize) / (floatSize * ic))
            sawInput = true
        }
    }
    if !sawInput { frames = 0 }

    // 1. De-interleave into scratch.
    var inChannels = 0
    var loudest: Float = 0
    if frames > 0 {
        for ii in firstTap..<inList.count {
            let ib = inList[ii]
            let ic = Int(ib.mNumberChannels)
            guard ic > 0, let src = ib.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for c in 0..<ic where inChannels < RenderContext.maxChannels {
                let dst = ctx.scratch + inChannels * maxFrames
                var f = 0
                while f < frames {
                    let v = src[f * ic + c]
                    dst[f] = v
                    let a = abs(v)
                    if a > loudest { loudest = a }
                    f += 1
                }
                inChannels += 1
            }
        }
    }

    if loudest > ctx.peak.pointee { ctx.peak.pointee = loudest }

    // 2. EQ + gain.
    let gain = ctx.gain.pointee * (ctx.eq?.preampGain ?? 1)
    for c in 0..<inChannels {
        let buf = ctx.scratch + c * maxFrames
        ctx.eq?.process(channel: c, samples: buf, frames: frames)
        var f = 0
        while f < frames { buf[f] *= gain; f += 1 }
    }

    // 3. Write outputs.
    var outFlat = 0
    for oi in 0..<outList.count {
        let ob = outList[oi]
        let oc = Int(ob.mNumberChannels)
        guard oc > 0, let dst = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let outFrames = Int(ob.mDataByteSize) / (floatSize * oc)
        for c in 0..<oc {
            var f = 0
            if inChannels > 0 {
                let src = ctx.scratch + ((outFlat + c) % inChannels) * maxFrames
                let n = min(outFrames, frames)
                while f < n { dst[f * oc + c] = src[f]; f += 1 }
            }
            while f < outFrames { dst[f * oc + c] = 0; f += 1 }
        }
        outFlat += oc
    }
}
