import CoreML
import Foundation
import WhisperKit

/// Whisper running on the Apple Neural Engine / GPU through Core ML. The transcript uses large-v3 turbo
/// (quantized); voice commands get a small English model of their own, which answers several times sooner.
actor SpeechEngine {
    static let transcriptVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let commandVariant = "openai_whisper-base.en"
    let variant: String

    init(variant: String = SpeechEngine.transcriptVariant) { self.variant = variant }

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
        if let local = Self.localModelFolder(variant) {
            folder = local
        } else {
            stage("Downloading speech model…")
            folder = try await WhisperKit.download(variant: variant, downloadBase: Self.modelsDir, from: Self.repo) { p in
                progress(p.fractionCompleted)
            }
        }
        stage("Preparing speech model (first time takes a few minutes)…")
        // The command model stays on the CPU: about 0.4 s a phrase whatever else is happening, where on the
        // Neural Engine it took 0.2 s alone but up to 1.6 s while the transcript model was working.
        let compute = variant == Self.commandVariant ? ModelComputeOptions(audioEncoderCompute: .cpuOnly, textDecoderCompute: .cpuOnly) : nil
        let config = WhisperKitConfig(
            downloadBase: Self.modelsDir, modelFolder: folder.path, computeOptions: compute, verbose: false, logLevel: .none, prewarm: true, load: true, download: false)
        kit = try await WhisperKit(config)
    }

    static func localModelFolder(_ variant: String) -> URL? {
        let fm = FileManager.default
        let direct = modelsDir.appendingPathComponent(variant)
        let hub = modelsDir.appendingPathComponent("models/\(repo)/\(variant)")
        return [direct, hub].first { fm.fileExists(atPath: $0.appendingPathComponent("AudioEncoder.mlmodelc").path) }
    }

    /// `vocabulary` (names and terms to expect) and `previous` (what was just said on this input) are given
    /// to Whisper as its prompt, so names come out spelled right and a phrase cut mid-sentence carries on.
    /// `expectingPrompt` is for command inputs, where the prompt is the very phrases being listened for.
    func text(for audio: [Float], corrections: String, vocabulary: String = "", previous: String = "", expectingPrompt: Bool = false) async throws -> String {
        let audio = Self.normalized(audio)
        let terms = Self.terms(vocabulary: vocabulary, corrections: corrections)
        let prompt = promptTokens(terms: terms, previous: previous)
        var text = try await decode(audio, prompt: prompt)
        // On noise or music a prompted Whisper tends to recite its prompt. When the result is nothing but
        // prompt words, listen again without one: real speech still comes back as something, noise doesn't.
        if prompt != nil, !expectingPrompt, Self.isEcho(text, of: terms + [previous]), try await decode(audio, prompt: nil).isEmpty { text = "" }
        return Self.correct(text, with: corrections)
    }

    private func decode(_ audio: [Float], prompt: [Int]?) async throws -> String {
        guard let kit else { return "" }
        // WhisperKit skips anything of a second or less, which is most one- or two-word commands.
        let audio = audio.count > sampleRate * 5 / 4 ? audio : audio + [Float](repeating: 0, count: sampleRate * 5 / 4 - audio.count)
        var options = DecodingOptions(
            task: .transcribe, language: "en", temperature: 0, temperatureFallbackCount: 2, skipSpecialTokens: true, withoutTimestamps: true,
            suppressBlank: true, compressionRatioThreshold: 2.4, logProbThreshold: -1.0, noSpeechThreshold: 0.6)
        options.promptTokens = prompt
        if prompt != nil {
            options.firstTokenLogProbThreshold = nil  // WhisperKit would judge the first prompt step, not the first word
            kit.textDecoder.logitsFilters = [PromptGuard(endToken: kit.tokenizer?.specialTokens.endToken)]
        } else {
            kit.textDecoder.logitsFilters = []
        }
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        // Whisper's own rule: only treat a segment as silence when it is both "no speech" and low confidence.
        let parts = results.flatMap(\.segments)
            .filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob < -1.0) && $0.avgLogprob > -1.8 }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }  // a lone "." is not a phrase
        return Self.hallucinations.contains(text.lowercased()) ? "" : text
    }

    /// True when every word of `text` comes from the prompt.
    static func isEcho(_ text: String, of prompt: [String]) -> Bool {
        func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let known = Set(prompt.flatMap(words))
        let said = words(text)
        return !said.isEmpty && said.allSatisfy(known.contains)
    }

    /// Every prompt token is one more decoder step before the first word (about 15 ms each on an M-series
    /// Mac), so both parts are kept short: the terms cost up to ~0.6 s a phrase, the previous words ~0.2 s.
    private static let maxTermTokens = 40
    private static let maxPreviousTokens = 12

    private func promptTokens(terms: [String], previous: String) -> [Int]? {
        guard let tokenizer = kit?.tokenizer else { return nil }
        let special = tokenizer.specialTokens.specialTokenBegin
        func tokens(_ s: String) -> [Int] { s.isEmpty ? [] : tokenizer.encode(text: " " + s).filter { $0 < special } }
        var out: [Int] = []
        for term in terms {  // whole terms only: half a name teaches the wrong spelling
            let t = tokens(term + (term == terms.last ? "." : ","))
            guard out.count + t.count <= Self.maxTermTokens else { break }
            out += t
        }
        out += tokens(previous).suffix(Self.maxPreviousTokens)
        return out.isEmpty ? nil : out
    }

    /// The vocabulary (one term per line or comma-separated) plus the right-hand side of every correction.
    static func terms(vocabulary: String, corrections: String) -> [String] {
        let typed = vocabulary.split { $0.isNewline || $0 == "," }.map(String.init)
        let corrected = corrections.split(whereSeparator: \.isNewline).compactMap { $0.components(separatedBy: "=>").dropFirst().first }
        var seen = Set<String>()
        return (typed + corrected).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Brings a quiet feed up to a steady level (Whisper degrades on low-level audio) without clipping.
    static func normalized(_ audio: [Float], targetRMS: Float = 0.07, maxGain: Float = 30) -> [Float] {
        guard !audio.isEmpty else { return audio }
        var sum: Float = 0, peak: Float = 0
        for x in audio { sum += x * x; peak = max(peak, abs(x)) }
        let rms = (sum / Float(audio.count)).squareRoot()
        guard rms > 1e-5, peak > 0 else { return audio }
        let gain = min(maxGain, targetRMS / rms, 0.95 / peak)
        guard gain > 1.05 else { return audio }  // never turn loud audio down
        return audio.map { $0 * gain }
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

/// WhisperKit feeds the prompt through the decoder one token at a time and stops the whole phrase if the
/// model happens to predict "end of text" at any of those steps, returning nothing. This keeps "end of text"
/// off the table until the prompt has been read; the first real word may still be it (that is how silence
/// comes back empty).
private final class PromptGuard: LogitsFiltering {
    private let endIndex: [[NSNumber]]
    private var promptLength = 0
    private var step = 0

    init(endToken: Int?) { endIndex = endToken.map { [[0, 0, $0 as NSNumber]] } ?? [] }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        if promptLength == 0 { promptLength = tokens.count }  // the first call sees just the prompt
        guard tokens.count == promptLength else { step = 0; return logits }  // past the prompt (a retry starts over)
        step += 1
        if step == promptLength { step = 0; return logits }  // the last prompt step predicts the first word
        logits.fill(indexes: endIndex, with: -FloatType.infinity)
        return logits
    }
}
