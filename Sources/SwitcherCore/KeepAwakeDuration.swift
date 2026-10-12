import Foundation

/// Durations for keeping the display awake, in whole minutes. Text is Russian,
/// like the rest of the menu.
public enum KeepAwakeDuration {
    public static let presets = [15, 30, 60, 120, 240]
    public static let maximumMinutes = 24 * 60

    /// Accepts `45` (minutes), `1:30`, `2 ч`, `1 ч 30 мин`, `1,5 ч`, `90m`.
    /// Minutes must be whole numbers; fractional hours are rounded.
    /// Returns nil for anything else, zero, or more than 24 hours.
    public static func parse(_ text: String) -> Int? {
        let input = text.lowercased().replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if input.allSatisfy(\.isASCIIDigit) { return bounded(Int(input)) }
        let clock = input.split(separator: ":", omittingEmptySubsequences: false)
        if clock.count == 2 {
            guard clock.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }),
                  clock[1].count == 2, let hours = Int(clock[0]), let minutes = Int(clock[1]), minutes < 60 else { return nil }
            return bounded(hours * 60 + minutes)
        }
        return unitTotal(input)
    }

    /// Menu titles: "15 минут", "1 час", "4 часа", "1 ч 30 мин".
    public static func title(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) \(plural(rest, "минута", "минуты", "минут"))" }
        if rest == 0 { return "\(hours) \(plural(hours, "час", "часа", "часов"))" }
        return "\(hours) ч \(rest) мин"
    }

    /// Time left, rounded up to the minute: "1 ч 12 мин", "45 мин", "меньше минуты".
    public static func remaining(seconds: Double) -> String {
        guard seconds > 0 else { return "меньше минуты" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 && seconds < 60 { return "меньше минуты" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) мин" }
        return rest == 0 ? "\(hours) ч" : "\(hours) ч \(rest) мин"
    }

    public static func plural(_ value: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = value % 100, units = value % 10
        if (11...14).contains(tens) { return many }
        if units == 1 { return one }
        if (2...4).contains(units) { return few }
        return many
    }

    private static func bounded(_ minutes: Int?) -> Int? {
        guard let minutes, (1...maximumMinutes).contains(minutes) else { return nil }
        return minutes
    }

    private static let hourUnits: Set<String> = ["ч", "час", "часа", "часов", "h", "hr", "hrs", "hour", "hours"]
    private static let minuteUnits: Set<String> = ["м", "мин", "минута", "минуту", "минуты", "минут", "m", "min", "mins", "minute", "minutes"]

    /// Number–unit pairs, each unit at most once, nothing else in the text.
    private static func unitTotal(_ input: String) -> Int? {
        var hours: Double?, minutes: Double?
        var rest = Substring(input)
        while true {
            rest = rest.drop(while: \.isWhitespace)
            if rest.isEmpty { break }
            let number = rest.prefix(while: { $0.isASCIIDigit || $0 == "." })
            guard !number.isEmpty, let value = Double(number) else { return nil }
            rest = rest.dropFirst(number.count).drop(while: \.isWhitespace)
            let unit = String(rest.prefix(while: \.isLetter))
            guard !unit.isEmpty else { return nil }
            rest = rest.dropFirst(unit.count)
            if hourUnits.contains(unit), hours == nil { hours = value }
            else if minuteUnits.contains(unit), minutes == nil, value == value.rounded() { minutes = value }
            else { return nil }
        }
        // Fractional hours round to the nearest minute: 1.1 h is 66 min.
        return bounded(Int(((hours ?? 0) * 60 + (minutes ?? 0)).rounded()))
    }
}

/// On battery power, keeping the display awake stops below this charge.
public enum KeepAwakeBatteryRule {
    public static let minimumPercent = 20

    /// `percent` is nil on a Mac without a battery.
    public static func allows(onBattery: Bool, percent: Int?) -> Bool {
        guard onBattery, let percent else { return true }
        return percent >= minimumPercent
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
