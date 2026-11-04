import Foundation

public enum TimeFormat {
    /// 'just now', '4m ago', '2h ago', 'yesterday', '3d ago'.
    public static func relativePast(epoch: Int, now: Date, calendar: Calendar = .current) -> String {
        let then = Date(timeIntervalSince1970: TimeInterval(epoch))
        let diff = Int(now.timeIntervalSince(then))
        if diff < 60 { return "just now" }          // includes slight clock skew into the future
        if diff < 3600 { return "\(diff / 60)m ago" }
        if diff < 12 * 3600 || calendar.isDate(then, inSameDayAs: now) { return "\(diff / 3600)h ago" }
        if calendar.isDateInYesterday(then, relativeTo: now) { return "yesterday" }
        return "\(max(2, diff / 86400))d ago"
    }

    /// 'in 12m', 'in 3h', 'tomorrow', 'due now'.
    public static func relativeFuture(epoch: Int, now: Date, calendar: Calendar = .current) -> String {
        let then = Date(timeIntervalSince1970: TimeInterval(epoch))
        let diff = Int(then.timeIntervalSince(now))
        if diff <= 60 { return "due now" }
        if diff < 3600 { return "in \(diff / 60)m" }
        if diff < 86400 && calendar.isDate(then, inSameDayAs: now) { return "in \(diff / 3600)h" }
        if calendar.isDate(then, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now) { return "tomorrow" }
        return "in \(max(2, diff / 86400))d"
    }
}

extension Calendar {
    func isDateInYesterday(_ d: Date, relativeTo now: Date) -> Bool {
        guard let y = date(byAdding: .day, value: -1, to: now) else { return false }
        return isDate(d, inSameDayAs: y)
    }
}
