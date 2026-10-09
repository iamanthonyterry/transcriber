import Foundation
import UserNotifications

/// Watches the audio that feeds the website for the two things that quietly ruin a transcript:
/// a feed that has gone silent (muted channel, pulled cable) and one that is clipping.
final class FeedWatch: @unchecked Sendable {
    private let lock = NSLock()
    private let minDb: Float
    private var lastSound = Date()
    private var clips: [Date] = []  // one entry per second in which a sample hit the ceiling

    init(minDb: Double) { self.minDb = Float(minDb) }

    /// Called on the audio queue with every buffer.
    func feed(_ samples: [Float], now: Date = Date()) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0, peak: Float = 0
        for x in samples { sum += x * x; peak = max(peak, abs(x)) }
        let db = 20 * log10(sqrt(sum / Float(samples.count)) + 1e-9)
        lock.lock()
        if db > minDb { lastSound = now }
        if peak >= 0.999, now.timeIntervalSince(clips.last ?? .distantPast) >= 1 { clips.append(now) }
        lock.unlock()
    }

    /// What is wrong right now, if anything. `silentAfter` is in minutes (0 = don't warn about silence).
    func warning(silentAfter minutes: Int, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        clips.removeAll { now.timeIntervalSince($0) > 30 }
        if clips.count >= 3 { return "The input is clipping — lower the level sent to this Mac" }
        if minutes > 0, now.timeIntervalSince(lastSound) >= Double(minutes) * 60 {
            return "No sound for \(Int(now.timeIntervalSince(lastSound)) / 60) min — check the feed and that the mic is unmuted"
        }
        return nil
    }
}

enum Notifier {
    @MainActor private static var last = Date.distantPast

    /// A macOS notification (asks for permission the first time). Does nothing when run outside the app bundle.
    @MainActor static func post(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil, Date().timeIntervalSince(last) > 600 else { return }  // a flapping warning mustn't nag
        last = Date()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
