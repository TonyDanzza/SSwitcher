import XCTest
@testable import SwitcherCore

final class KeepAwakeDurationTests: XCTestCase {
    func testParsesMinutesClockAndUnits() {
        XCTAssertEqual(KeepAwakeDuration.parse("45"), 45)
        XCTAssertEqual(KeepAwakeDuration.parse(" 90 "), 90)
        XCTAssertEqual(KeepAwakeDuration.parse("1:30"), 90)
        XCTAssertEqual(KeepAwakeDuration.parse("0:05"), 5)
        XCTAssertEqual(KeepAwakeDuration.parse("2 ч"), 120)
        XCTAssertEqual(KeepAwakeDuration.parse("3 ч 20 мин"), 200)
        XCTAssertEqual(KeepAwakeDuration.parse("1ч30м"), 90)
        XCTAssertEqual(KeepAwakeDuration.parse("2 часа 15 минут"), 135)
        XCTAssertEqual(KeepAwakeDuration.parse("1,5 ч"), 90)
        XCTAssertEqual(KeepAwakeDuration.parse("1.5h"), 90)
        XCTAssertEqual(KeepAwakeDuration.parse("1,1 ч"), 66)
        XCTAssertEqual(KeepAwakeDuration.parse("1.33 ч"), 80)
        XCTAssertEqual(KeepAwakeDuration.parse("40 Мин"), 40)
        XCTAssertEqual(KeepAwakeDuration.parse("90m"), 90)
        XCTAssertEqual(KeepAwakeDuration.parse("24 ч"), 1440)
    }

    func testRejectsAmbiguousEmptyAndOutOfRangeInput() {
        for text in ["", "  ", "0", "0 мин", "1:5", "1:60", ":30", "1:", "abc", "2 ч 3", "ч 30",
                     "1 ч 1 ч", "1.5 мин", "25 ч", "1441", "2 дня", "-5", "1.5"] {
            XCTAssertNil(KeepAwakeDuration.parse(text), text)
        }
    }

    func testTitlesUseRussianPlurals() {
        XCTAssertEqual(KeepAwakeDuration.title(minutes: 15), "15 минут")
        XCTAssertEqual(KeepAwakeDuration.title(minutes: 21), "21 минута")
        XCTAssertEqual(KeepAwakeDuration.title(minutes: 22), "22 минуты")
        XCTAssertEqual(KeepAwakeDuration.title(minutes: 60), "1 час")
        XCTAssertEqual(KeepAwakeDuration.title(minutes: 120), "2 часа")
        XCTAssertEqual(KeepAwakeDuration.title(minutes: 300), "5 часов")
        XCTAssertEqual(KeepAwakeDuration.title(minutes: 660), "11 часов")
        XCTAssertEqual(KeepAwakeDuration.title(minutes: 1260), "21 час")
        XCTAssertEqual(KeepAwakeDuration.title(minutes: 200), "3 ч 20 мин")
    }

    func testRemainingTimeRoundsUpToTheMinute() {
        XCTAssertEqual(KeepAwakeDuration.remaining(seconds: 0), "меньше минуты")
        XCTAssertEqual(KeepAwakeDuration.remaining(seconds: 30), "меньше минуты")
        XCTAssertEqual(KeepAwakeDuration.remaining(seconds: 60), "1 мин")
        XCTAssertEqual(KeepAwakeDuration.remaining(seconds: 61), "2 мин")
        XCTAssertEqual(KeepAwakeDuration.remaining(seconds: 45 * 60), "45 мин")
        XCTAssertEqual(KeepAwakeDuration.remaining(seconds: 3600), "1 ч")
        XCTAssertEqual(KeepAwakeDuration.remaining(seconds: 3600 + 11 * 60 + 5), "1 ч 12 мин")
    }

    func testBatteryRuleStopsOnlyOnBatteryBelowTwentyPercent() {
        XCTAssertTrue(KeepAwakeBatteryRule.allows(onBattery: false, percent: 5))
        XCTAssertTrue(KeepAwakeBatteryRule.allows(onBattery: true, percent: 20))
        XCTAssertFalse(KeepAwakeBatteryRule.allows(onBattery: true, percent: 19))
        XCTAssertTrue(KeepAwakeBatteryRule.allows(onBattery: true, percent: nil))
    }
}
