import AVFoundation
import Foundation

/// `Transcriber --transcribe-file x.wav`: runs the same segmenter + Whisper pipeline on a recording and
/// prints each phrase. For testing without a mixer. Sends nothing to the website.
/// Add `--vocabulary "Name, Term"` to try names and terms, and `--commands` to treat it as a commands-only input.
enum FileTest {
    static func run(path: String, vocabulary: String = "", commands: Bool = false, model: String? = nil) {
        Task.detached {
            do {
                let samples = try load(path)
                let engine = SpeechEngine(variant: model ?? (commands ? SpeechEngine.commandVariant : SpeechEngine.transcriptVariant))
                try await engine.load(progress: { print(String(format: "download %.0f%%", $0 * 100)) }, stage: { print($0) })
                let seg = Segmenter(minDb: -50, endPause: commands ? 0.3 : 0.5)
                var phrases = seg.feed(samples: samples)
                if let tail = seg.flush() { phrases.append(tail) }
                print("\(phrases.count) phrase(s) detected")
                var previous = ""
                let gate = SpeechGate()
                for p in phrases {
                    let t0 = Date()
                    let confidence = gate.speechConfidence(SpeechEngine.normalized(p))
                    if let c = confidence, c < SpeechGate.threshold {
                        print(String(format: "(skipped %.1fs of audio: speech %.2f, checked in %.3fs)", Double(p.count) / Double(sampleRate), c, Date().timeIntervalSince(t0)))
                        continue
                    }
                    let text = try await engine.text(for: p, corrections: defaultCorrections, vocabulary: vocabulary,
                                                     previous: commands ? "" : previous, expectingPrompt: commands)
                    if !text.isEmpty { previous = text }
                    print(String(format: "(%.1fs for %.1fs of audio, speech %.2f) %@", Date().timeIntervalSince(t0), Double(p.count) / Double(sampleRate), confidence ?? -1, text))
                }
                exit(0)
            } catch {
                print("error:", error)
                exit(1)
            }
        }
    }

    static func levelCheck(path: String) {
        do {
            let check = LevelCheck()
            check.begin()
            check.feed(try load(path))
            let r = check.finish()
            print("\(r.title): speech \(Int(r.speechDb)) dB, background \(Int(r.noiseDb)) dB, peak \(Int(r.peakDb)) dB\n\(r.advice)")
            exit(0)
        } catch {
            print("error:", error)
            exit(1)
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
