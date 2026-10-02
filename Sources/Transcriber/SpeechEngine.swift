import Foundation
import WhisperKit

/// Whisper (large-v3 turbo, quantized) running on the Apple Neural Engine / GPU through Core ML.
actor SpeechEngine {
    static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let repo = "argmaxinc/whisperkit-coreml"

    /// Where models live. To set up a Mac with no internet, copy a model folder here beforehand.
    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber/Models", isDirectory: true)
    }

    private var kit: WhisperKit?

    private static let hallucinations: Set<String> = ["thank you", "thank you.", "thanks for watching", "thanks for watching!", "you", "bye", "bye."]

    var isLoaded: Bool { kit != nil }

    /// Loads the model, downloading it the first time only. `progress` gets 0...1 while downloading.
    func load(progress: @escaping @Sendable (Double) -> Void, stage: @escaping @Sendable (String) -> Void) async throws {
        guard kit == nil else { return }
        let folder: URL
        if let local = Self.localModelFolder() {
            folder = local
        } else {
            stage("Downloading speech model…")
            folder = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.modelsDir, from: Self.repo) { p in
                progress(p.fractionCompleted)
            }
        }
        stage("Preparing speech model (first time takes a few minutes)…")
        let config = WhisperKitConfig(
            downloadBase: Self.modelsDir, modelFolder: folder.path, verbose: false, logLevel: .none, prewarm: true, load: true, download: false)
        kit = try await WhisperKit(config)
    }

    private static func localModelFolder() -> URL? {
        let fm = FileManager.default
        let direct = modelsDir.appendingPathComponent(variant)
        let hub = modelsDir.appendingPathComponent("models/\(repo)/\(variant)")
        return [direct, hub].first { fm.fileExists(atPath: $0.appendingPathComponent("AudioEncoder.mlmodelc").path) }
    }

    func text(for audio: [Float], corrections: String) async throws -> String {
        guard let kit else { return "" }
        let options = DecodingOptions(
            task: .transcribe, language: "en", temperature: 0, skipSpecialTokens: true, withoutTimestamps: true,
            compressionRatioThreshold: 2.4, logProbThreshold: -1.0, noSpeechThreshold: 0.6)
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        let parts = results.flatMap(\.segments)
            .filter { $0.noSpeechProb < 0.6 && $0.avgLogprob > -1.2 }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return Self.hallucinations.contains(text.lowercased()) ? "" : Self.correct(text, with: corrections)
    }

    /// "heard => correct" lines, matched whole-word and case-insensitively.
    static func correct(_ text: String, with corrections: String) -> String {
        var out = text
        for line in corrections.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let heard = parts[0].trimmingCharacters(in: .whitespaces), right = parts[1].trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty, let re = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: heard) + "\\b", options: .caseInsensitive) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: NSRegularExpression.escapedTemplate(for: right))
        }
        return out
    }
}
