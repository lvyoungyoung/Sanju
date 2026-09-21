import Foundation

enum StudyCalendar {
    static let timeZoneHeader = "x-sanju-study-time-zone"

    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func dayString(from date: Date?, timeZone: TimeZone = .current) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar(timeZone: timeZone)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func applyTimeZone(to request: inout URLRequest, timeZone: TimeZone = .current) {
        request.setValue(timeZone.identifier, forHTTPHeaderField: timeZoneHeader)
    }

    static var currentDayContext: String {
        let zone = TimeZone.current
        return zone.identifier + ":" + (dayString(from: .now, timeZone: zone) ?? "")
    }
}
