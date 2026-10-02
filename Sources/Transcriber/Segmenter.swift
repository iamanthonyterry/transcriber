import Foundation

let sampleRate = 16_000
let frameSize = 480  // 30 ms

/// Energy-based speech detector that cuts audio into phrases.
/// The noise floor adapts, so it copes with different mixers and rooms. A phrase ends after a short
/// pause; long run-on speech is cut at the next small pause.
final class Segmenter {
    private let minDb: Float
    private let marginDb: Float = 9
    private var floor: Float
    private var preroll: [[Float]] = []  // 300 ms before speech starts
    private var buf: [[Float]] = []
    private var speaking = false
    private var silentFrames = 0
    private var speechFrames = 0
    private var pending: [Float] = []

    init(minDb: Double) {
        self.minDb = Float(minDb)
        floor = Float(minDb) - 6
    }

    /// Accepts any amount of audio; returns every phrase completed by it.
    func feed(samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var phrases: [[Float]] = []
        var i = 0
        while pending.count - i >= frameSize {
            if let p = feed(frame: Array(pending[i..<i + frameSize])) { phrases.append(p) }
            i += frameSize
        }
        pending.removeFirst(i)
        return phrases
    }

    private func levelDb(_ f: [Float]) -> Float {
        var sum: Float = 0
        for x in f { sum += x * x }
        return 20 * log10(sqrt(sum / Float(f.count)) + 1e-9)
    }

    private func feed(frame: [Float]) -> [Float]? {
        let db = levelDb(frame)
        let loud = db > max(minDb, floor + marginDb)
        if !loud { floor = 0.98 * floor + 0.02 * db }  // track the noise floor only while it is quiet

        if !speaking {
            preroll.append(frame)
            if preroll.count > 10 { preroll.removeFirst() }
            if loud {
                speechFrames += 1
                if speechFrames >= 3 {  // ~90 ms of sound, ignore clicks
                    speaking = true
                    buf = preroll
                    silentFrames = 0
                }
            } else {
                speechFrames = 0
            }
            return nil
        }

        buf.append(frame)
        silentFrames = loud ? 0 : silentFrames + 1
        let seconds = Float(buf.count * frameSize) / Float(sampleRate)
        let pause = Float(silentFrames * frameSize) / Float(sampleRate)
        let done = pause >= 0.7 || (seconds >= 12 && pause >= 0.25) || seconds >= 22
        guard done else { return nil }
        let audio = buf.flatMap { $0 }
        reset()
        return seconds - pause >= 0.4 ? audio : nil  // drop blips
    }

    func flush() -> [Float]? {
        guard speaking, !buf.isEmpty else { return nil }
        let audio = buf.flatMap { $0 }
        reset()
        return audio
    }

    private func reset() {
        buf = []
        speaking = false
        silentFrames = 0
        speechFrames = 0
        preroll = []
    }
}
