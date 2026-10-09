import AVFoundation

/// Subtitle files from timed phrases. Times are seconds from the start of the session.
enum Subtitles {
    struct Cue {
        var start: Double
        var end: Double
        var text: String
    }

    static func srt(_ cues: [Cue]) -> String {
        tidy(cues).enumerated().map { i, c in "\(i + 1)\n\(clock(c.start, ","))" + " --> " + "\(clock(c.end, ","))\n\(c.text)\n" }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + tidy(cues).map { c in "\(clock(c.start, "."))" + " --> " + "\(clock(c.end, "."))\n\(c.text)\n" }.joined(separator: "\n")
    }

    /// In order, never negative, and each cue ends before the next begins (players dislike overlaps).
    private static func tidy(_ cues: [Cue]) -> [Cue] {
        var out = cues.sorted { $0.start < $1.start }
        for i in out.indices {
            out[i].start = max(0, out[i].start)
            out[i].end = max(out[i].end, out[i].start + 0.5)
            if i + 1 < out.count { out[i].end = min(out[i].end, max(out[i].start, out[i + 1].start)) }
        }
        return out
    }

    private static func clock(_ seconds: Double, _ decimal: String) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, decimal, ms % 1000)
    }
}

/// Records a session's audio as a small AAC file (about 20 MB an hour). Its timeline is the session's:
/// time zero is `start`, and any gap in the audio (waiting for the model, a restart, an unplugged device)
/// is filled with silence, so the subtitle files stay in sync with it.
final class Recorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "audio.record")
    private let start: Date
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    private var file: AVAudioFile?
    private var written = 0

    init(url: URL, start: Date) {
        self.start = start
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        file = try? AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func feed(_ samples: [Float]) {
        let now = Date()
        queue.async { [self] in
            let due = Int(now.timeIntervalSince(start) * Double(sampleRate)) - samples.count  // where these samples belong
            var gap = due - written
            let silence = [Float](repeating: 0, count: sampleRate * 10)
            while gap > sampleRate / 2 {  // in pieces: a long wait must not become one huge buffer
                let n = min(gap, silence.count)
                write(Array(silence[..<n]))
                gap -= n
            }
            write(samples)
        }
    }

    private func write(_ samples: [Float]) {
        guard let file, !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if (try? file.write(from: buffer)) != nil { written += samples.count }
    }

    deinit { queue.sync { file = nil } }  // closing the file is what makes it playable
}
