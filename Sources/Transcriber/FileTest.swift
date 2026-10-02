import AVFoundation
import Foundation

/// `Transcriber --transcribe-file x.wav`: runs the same segmenter + Whisper pipeline on a recording and
/// prints each phrase. For testing without a mixer. Sends nothing to the website.
enum FileTest {
    static func run(path: String) {
        Task.detached {
            do {
                let samples = try load(path)
                let engine = SpeechEngine()
                try await engine.load(progress: { print(String(format: "download %.0f%%", $0 * 100)) }, stage: { print($0) })
                let seg = Segmenter(minDb: -50)
                var phrases = seg.feed(samples: samples)
                if let tail = seg.flush() { phrases.append(tail) }
                print("\(phrases.count) phrase(s) detected")
                for p in phrases {
                    let t0 = Date()
                    let text = try await engine.text(for: p, corrections: defaultCorrections)
                    print(String(format: "(%.1fs for %.1fs of audio) %@", Date().timeIntervalSince(t0), Double(p.count) / Double(sampleRate), text))
                }
                exit(0)
            } catch {
                print("error:", error)
                exit(1)
            }
        }
    }

    private static func load(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target),
              let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw CaptureError(message: "can't read file") }
        try file.read(into: inBuf)
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 1024)!
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let err { throw err }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
