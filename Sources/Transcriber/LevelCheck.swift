import Foundation

struct LevelCheckResult: Equatable {
    enum Verdict { case noSignal, tooQuiet, good, tooLoud, clipping, noisy }
    var verdict: Verdict
    var speechDb: Double   // typical level while talking (loudest 10% of 30 ms frames)
    var noiseDb: Double    // background level between words (quietest 20%)
    var peakDb: Double     // highest sample

    var snr: Double { speechDb - noiseDb }

    var title: String {
        switch verdict {
        case .noSignal: "No signal"
        case .tooQuiet: "Too quiet"
        case .good: "Level is good"
        case .tooLoud: "Too loud"
        case .clipping: "Clipping"
        case .noisy: "Too much background noise"
        }
    }

    var advice: String {
        switch verdict {
        case .noSignal: "Nothing is coming in. Check the input and channel above, and that the speaker's mic is unmuted and up on the board."
        case .tooQuiet: "Raise the output to the Mac on the board or the interface's input gain until speech sits around −30 to −18 dB."
        case .good: "Speech is a healthy level with room to spare."
        case .tooLoud: "Lower the gain a little. Speech should sit around −30 to −18 dB, not near the top."
        case .clipping: "The signal is hitting the ceiling and distorting, which hurts accuracy. Lower the gain on the board or interface."
        case .noisy: "Speech is only \(Int(snr)) dB above the background. Use a clean feed of just the speaker's mic, not a room mic, and not during music."
        }
    }

    var isOK: Bool { verdict == .good }

    /// Judges a run of per-frame levels (dB RMS, 30 ms each) and the highest sample seen (linear, 0...1).
    static func evaluate(frameDb: [Double], peak: Double) -> LevelCheckResult {
        let peakDb = max(20 * log10(max(peak, 1e-6)), -90)
        guard frameDb.count >= 10 else { return LevelCheckResult(verdict: .noSignal, speechDb: -90, noiseDb: -90, peakDb: peakDb) }
        let sorted = frameDb.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let speech = max(pct(0.9), -90), noise = max(pct(0.2), -90)
        let verdict: Verdict
        if peakDb < -55 || speech < -60 { verdict = .noSignal }
        else if peakDb > -0.5 { verdict = .clipping }
        else if speech < -38 { verdict = .tooQuiet }
        else if speech > -14 || peakDb > -3 { verdict = .tooLoud }
        else if speech - noise < 15 { verdict = .noisy }
        else { verdict = .good }
        return LevelCheckResult(verdict: verdict, speechDb: speech, noiseDb: noise, peakDb: peakDb)
    }
}

/// Collects levels from a capture's sample stream while a check is running.
final class LevelCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var frames: [Double] = []
    private var peak = 0.0
    private var pending: [Float] = []

    func begin() {
        lock.lock(); defer { lock.unlock() }
        frames = []; peak = 0; pending = []; active = true
    }

    func finish() -> LevelCheckResult {
        lock.lock(); defer { lock.unlock() }
        active = false
        return .evaluate(frameDb: frames, peak: peak)
    }

    func feed(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        pending.append(contentsOf: samples)
        var i = 0
        while pending.count - i >= frameSize {
            var sum: Float = 0
            for x in pending[i..<i + frameSize] { sum += x * x; peak = max(peak, Double(abs(x))) }
            frames.append(Double(20 * log10((sum / Float(frameSize)).squareRoot() + 1e-9)))
            i += frameSize
        }
        pending.removeFirst(i)
    }
}
