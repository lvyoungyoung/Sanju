import XCTest
@testable import 三句

final class StudyCalendarTests: XCTestCase {
    private func date(_ string: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: string))
    }

    func testSameInstantUsesDeviceCalendarDate() throws {
        let instant = try date("2026-09-21T02:30:00Z")
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(StudyCalendar.dayString(from: instant, timeZone: losAngeles), "2026-09-20")
        XCTAssertEqual(StudyCalendar.dayString(from: instant, timeZone: shanghai), "2026-09-21")
        XCTAssertNil(StudyCalendar.dayString(from: nil, timeZone: losAngeles))
    }

    func testHeaderAndUploadDatesUseTheSameZone() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid/rest/v1/rpc/count_sentence_study_queue")))
        StudyCalendar.applyTimeZone(to: &request, timeZone: zone)
        XCTAssertEqual(request.value(forHTTPHeaderField: StudyCalendar.timeZoneHeader), zone.identifier)
        let instant = try date("2026-09-20T12:00:00Z")
        XCTAssertEqual(StudyCalendar.dayString(from: instant, timeZone: zone), "2026-09-21")
        XCTAssertEqual(StudyCalendar.calendar(timeZone: zone).identifier, .gregorian)
    }

    func testDaylightSavingStillSchedulesTheNextCalendarDay() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let calendar = StudyCalendar.calendar(timeZone: zone)
        for (instant, hours) in [("2026-03-08T12:00:00Z", 23), ("2026-11-01T12:00:00Z", 25)] {
            let day = calendar.startOfDay(for: try date(instant))
            let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
            XCTAssertEqual(nextDay.timeIntervalSince(day), Double(hours * 3600))
        }
    }

    func testActualStudyTimeNotOldMidnightDeterminesTodayAfterTravel() throws {
        let calendar = StudyCalendar.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")))
        let oldShanghaiMidnight = try date("2026-09-20T16:00:00Z")
        let actualStudyTime = try date("2026-09-21T08:30:00Z")
        let currentTime = try date("2026-09-21T10:00:00Z")
        XCTAssertFalse(calendar.isDate(oldShanghaiMidnight, inSameDayAs: currentTime))
        XCTAssertTrue(calendar.isDate(actualStudyTime, inSameDayAs: currentTime))
    }
}
