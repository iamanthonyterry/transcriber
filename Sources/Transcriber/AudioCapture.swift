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

    /// Returns nil on success, or the CoreAudio error code.
    static func setDefaultInput(_ id: AudioDeviceID) -> OSStatus? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = id
        let err = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        return err == noErr ? nil : err
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
final class AudioCapture {
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var previousDefault: AudioDeviceID?

    /// `onSamples` is called on an audio thread; hand the work off quickly.
    /// `onInterrupted` fires when macOS changes the audio setup (device unplugged, sample rate change).
    func start(device: InputDevice?, channel: Int, onSamples: @escaping ([Float]) -> Void, onInterrupted: @escaping () -> Void) throws {
        stop()
        // AVAudioEngine's AUHAL refuses input-only devices ('nope'), so switch the system
        // default input for the duration of the recording and restore it in stop().
        if let device, AudioDevices.defaultInput() != device.id {
            previousDefault = AudioDevices.defaultInput()
            if let err = AudioDevices.setDefaultInput(device.id) {
                previousDefault = nil
                throw CaptureError(message: "Couldn't select “\(device.name)” (error \(err))")
            }
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.channelCount > 0, hw.sampleRate > 0 else { throw CaptureError(message: "No audio input available") }
        guard channel >= 1, channel <= Int(hw.channelCount) else {
            throw CaptureError(message: "Channel \(channel) chosen but the input has only \(hw.channelCount)")
        }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.sampleRate, channels: 1, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: mono, to: target) else { throw CaptureError(message: "Unsupported audio format") }
        let index = channel - 1

        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { buffer, _ in
            guard let src = buffer.floatChannelData, buffer.frameLength > 0,
                  let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return }
            m.frameLength = buffer.frameLength
            memcpy(m.floatChannelData![0], src[index], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / hw.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return m
            }
            if error == nil, out.frameLength > 0, let data = out.floatChannelData {
                onSamples(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
            }
        }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            onInterrupted()
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let prev = previousDefault { _ = AudioDevices.setDefaultInput(prev) }
        previousDefault = nil
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
