import Foundation

/// When the app listens if "Only during schedule" is on: chosen weekdays between a start and end time.
enum Schedule {
    static func inWindow(_ s: Settings, _ now: Date = Date()) -> Bool {
        if s.pcoOn { return s.pcoTimes.contains { pcoWindow(s, $0).contains(now) } }
        let cal = Calendar.current
        let c = cal.dateComponents([.weekday, .hour, .minute], from: now)
        let minutes = c.hour! * 60 + c.minute!
        return s.scheduleWindows.contains { w in
            let today = w.date.map { cal.isDate(now, inSameDayAs: $0) } ?? w.days.contains(c.weekday!)
            return today && minutes >= w.start && minutes < w.end
        }
    }

    /// The listening window around one Planning Center service time.
    static func pcoWindow(_ s: Settings, _ start: Date) -> Range<Date> {
        start.addingTimeInterval(-Double(s.pcoLeadMinutes) * 60) ..< start.addingTimeInterval(Double(s.pcoLengthMinutes) * 60)
    }

    /// The window that is happening now or comes next, if any.
    static func nextPCOWindow(_ s: Settings, _ now: Date = Date()) -> Range<Date>? {
        s.pcoTimes.map { pcoWindow(s, $0) }.filter { $0.upperBound > now }.min { $0.lowerBound < $1.lowerBound }
    }

    static func summary(_ s: Settings) -> String {
        if s.pcoOn {
            let name = s.pcoServiceTypeName.isEmpty ? "Planning Center" : s.pcoServiceTypeName
            guard let w = nextPCOWindow(s) else { return "during \(name) (no upcoming times)" }
            let day = w.lowerBound.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            return "during \(name): \(day) \(w.lowerBound.formatted(date: .omitted, time: .shortened))–\(w.upperBound.formatted(date: .omitted, time: .shortened))"
        }
        let names = Calendar.current.shortWeekdaySymbols
        let parts = s.scheduleWindows.map { w -> String in
            let days = w.date.map { $0.formatted(.dateTime.month(.abbreviated).day()) }
                ?? w.days.sorted().map { names[$0 - 1] }.joined(separator: ", ")
            return "\(days.isEmpty ? "No days" : days) \(clock(w.start))–\(clock(w.end))"
        }
        return parts.isEmpty ? "No times set" : parts.joined(separator: "; ")
    }

    static func clock(_ minutes: Int) -> String {
        date(minutes).formatted(date: .omitted, time: .shortened)
    }

    static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    static func minutes(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return c.hour! * 60 + c.minute!
    }
}
