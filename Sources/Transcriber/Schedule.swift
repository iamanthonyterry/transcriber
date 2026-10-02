import Foundation

/// The one schedule the menu offers: Sundays 8:00–12:30.
enum Schedule {
    static func inWindow(_ now: Date = Date()) -> Bool {
        let c = Calendar.current.dateComponents([.weekday, .hour, .minute], from: now)
        guard c.weekday == 1 else { return false }  // Sunday
        let minutes = c.hour! * 60 + c.minute!
        return minutes >= 8 * 60 && minutes <= 12 * 60 + 30
    }
}
