import AVFoundation
import CoreAudio

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let channels: Int
}

enum AudioDevices {
    static func inputs() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let ch = inputChannels(id)
            return ch > 0 ? InputDevice(id: id, name: name(id), channels: ch) : nil
        }
    }

    static func defaultInput() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func name(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "Unknown" }
        return n.takeRetainedValue() as String
    }
}

struct CaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Records one channel of an input device and delivers 16 kHz mono Float32 samples.
/// Talks to the device directly (no system-default switching), so several captures can run at once.
final class AudioCapture {
    private var deviceID = AudioDeviceID(0)
    private var procID: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let ioQueue = DispatchQueue(label: "audio.capture.io", qos: .userInteractive)

    /// `onSamples` is called on an audio queue; hand the work off quickly.
    /// `onInterrupted` fires when macOS changes the audio setup (device unplugged, sample rate change).
    func start(device: InputDevice?, channel: Int, onSamples: @escaping ([Float]) -> Void, onInterrupted: @escaping () -> Void) throws {
        stop()
        let id = device?.id ?? AudioDevices.defaultInput()
        let total = id == 0 ? 0 : AudioDevices.inputChannels(id)
        guard total > 0 else { throw CaptureError(message: "No audio input available") }
        guard channel >= 1, channel <= total else {
            throw CaptureError(message: "Channel \(channel) chosen but “\(AudioDevices.name(id))” has only \(total)")
        }

        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(id, &fmtAddr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32
        else { throw CaptureError(message: "Unsupported audio format on “\(AudioDevices.name(id))”") }

        let rate = asbd.mSampleRate
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        let converter = rate == target.sampleRate ? nil : AVAudioConverter(from: mono, to: target)
        if rate != target.sampleRate && converter == nil { throw CaptureError(message: "Unsupported audio format") }
        let wanted = channel - 1

        var proc: AudioDeviceIOProcID?
        let made = AudioDeviceCreateIOProcIDWithBlock(&proc, id, ioQueue) { _, inData, _, _, _ in
            // The buffers may be one interleaved block or one per channel; find the one holding our channel.
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            var offset = 0
            for buf in list {
                let n = Int(buf.mNumberChannels)
                if n > 0, wanted < offset + n, let data = buf.mData?.assumingMemoryBound(to: Float.self) {
                    let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * n)
                    guard frames > 0 else { return }
                    let col = wanted - offset
                    var samples = [Float](repeating: 0, count: frames)
                    for i in 0..<frames { samples[i] = data[i * n + col] }
                    guard let converter else { onSamples(samples); return }
                    guard let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)) else { return }
                    m.frameLength = AVAudioFrameCount(frames)
                    memcpy(m.floatChannelData![0], samples, frames * MemoryLayout<Float>.size)
                    let cap = AVAudioFrameCount(Double(frames) * target.sampleRate / rate) + 32
                    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
                    var fed = false
                    var error: NSError?
                    converter.convert(to: out, error: &error) { _, status in
                        if fed { status.pointee = .noDataNow; return nil }
                        fed = true
                        status.pointee = .haveData
                        return m
                    }
                    if error == nil, out.frameLength > 0, let o = out.floatChannelData {
                        onSamples(Array(UnsafeBufferPointer(start: o[0], count: Int(out.frameLength))))
                    }
                    return
                }
                offset += n
            }
        }
        guard made == noErr, let proc else { throw CaptureError(message: "Couldn't open “\(AudioDevices.name(id))” (error \(made))") }
        deviceID = id
        procID = proc

        // An unplugged or re-clocked device (or a changed system default, when following it) means reconnect.
        var watch: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (id, AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)),
            (id, AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)),
        ]
        if device == nil {
            watch.append((AudioObjectID(kAudioObjectSystemObject), AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)))
        }
        for (object, address) in watch {
            var address = address
            let block: AudioObjectPropertyListenerBlock = { _, _ in onInterrupted() }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr { listeners.append((object, address, block)) }
        }

        let started = AudioDeviceStart(id, proc)
        if started != noErr {
            let name = AudioDevices.name(id)
            stop()
            throw CaptureError(message: "Couldn't start “\(name)” (error \(started))")
        }
    }

    func stop() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners = []
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = 0
    }
}
/// Turns the capture's sample callback into ~20 updates a second of the level in dB (same scale as the sensitivity slider).
final class LevelReporter: @unchecked Sendable {
    private var last = Date.distantPast
    private let handler: @Sendable (Double) -> Void
    init(_ handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }

    func feed(_ samples: [Float]) {
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.05, !samples.isEmpty else { return }
        last = now
        var sum: Float = 0
        for x in samples { sum += x * x }
        let db = Double(20 * log10(sqrt(sum / Float(samples.count)) + 1e-9))
        DispatchQueue.main.async { [handler] in handler(db) }
    }
}

enum MicPermission {
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
