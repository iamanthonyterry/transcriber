import AVFoundation
import SoundAnalysis

/// Tells talking from music, singing, applause and noise, using the sound classifier built into macOS
/// (on-device, nothing to download). The segmenter still decides where a phrase starts and ends; this
/// decides whether the phrase is worth giving to Whisper, which invents words for anything that isn't speech.
final class SpeechGate {
    /// Talking scores about 0.9 (0.8 over music as loud as the voice); singing and instruments about 0.2,
    /// with the odd sung line reaching 0.6. Set low on purpose: losing real words is worse than a stray lyric.
    static let threshold = 0.5

    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    private let window = 1.0  // seconds of audio the classifier judges at a time

    /// How sure the classifier is that the phrase is speech, 0...1 (nil when it couldn't be judged).
    func speechConfidence(_ audio: [Float]) -> Double? {
        let frames = max(audio.count, Int(window * Double(sampleRate)))  // shorter phrases are padded with silence
        guard !audio.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        audio.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: audio.count) }
        request.windowDuration = CMTime(seconds: window, preferredTimescale: CMTimeScale(sampleRate))
        request.overlapFactor = 0.5
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let scores = Scores()
        guard (try? analyzer.add(request, withObserver: scores)) != nil else { return nil }
        analyzer.analyze(buffer, atAudioFramePosition: 0)  // results arrive before this returns
        analyzer.completeAnalysis()
        // A phrase ends in a pause, so judge it by its best half rather than dragging the average down.
        let best = scores.speech.sorted(by: >).prefix(max(1, (scores.speech.count + 1) / 2))
        return best.isEmpty ? nil : best.reduce(0, +) / Double(best.count)
    }

    /// Unjudgeable audio counts as speech: losing real words is worse than transcribing a noise.
    func isSpeech(_ audio: [Float]) -> Bool { (speechConfidence(audio) ?? 1) >= Self.threshold }

    private final class Scores: NSObject, SNResultsObserving {
        var speech: [Double] = []
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            speech.append(r.classification(forIdentifier: "speech")?.confidence ?? 0)
        }
    }
}
