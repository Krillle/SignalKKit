import XCTest
@testable import SignalKKit

final class SignalKTimestampParserTests: XCTestCase {
    private func legacyDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    func testUTCWholeSecondsAndMillisecondsPreserveInstants() throws {
        let bases = ["1970-01-01T00:00:00", "2000-02-29T23:59:59",
                     "2024-02-29T12:34:56", "2026-12-31T23:59:59"]
        for base in bases {
            for suffix in ["Z", ".000Z", ".001Z", ".123Z", ".999Z"] {
                let string = base + suffix
                let actual = try XCTUnwrap(SignalKTimestampParser.date(from: string), string)
                let expected = try XCTUnwrap(legacyDate(string), string)
                XCTAssertEqual(actual, expected, string)
            }
        }
    }

    func testOffsetsOtherPrecisionAndMalformedInputsRetainLegacyBehavior() {
        for string in ["2026-09-12T12:34:56+02:00", "2026-09-12T12:34:56.123-05:30",
                       "2026-09-12T12:34:56.1Z", "2026-09-12T12:34:56.123456789Z",
                       "2026-09-12T12:34:56+0000", "2026-09-12T12:34:56z",
                       "2026-02-30T12:34:56Z", "2026-09-12T99:34:56Z", "2026-09-12T12:99:56Z",
                       "2026-09-12T12:34:99Z", "2026-13-12T12:34:56Z",
                       "2026-09-12T12:34:56.abcZ", "not-a-date", ""] {
            XCTAssertEqual(SignalKTimestampParser.date(from: string), legacyDate(string), string)
        }
        XCTAssertNil(SignalKTimestampParser.date(from: nil))
    }

    func testRepeatedAndOutOfOrderTimestampsDoNotBecomeArrivalTime() throws {
        let older = "2025-01-01T00:00:00.123Z"
        let newer = "2026-09-12T12:34:56.987Z"
        let first = try XCTUnwrap(SignalKTimestampParser.date(from: older))
        let second = try XCTUnwrap(SignalKTimestampParser.date(from: newer))
        XCTAssertLessThan(first, second)
        XCTAssertEqual(SignalKTimestampParser.date(from: older), first)
        XCTAssertEqual(SignalKTimestampParser.date(from: newer), second)
        XCTAssertNil(SignalKTimestampParser.date(from: nil))
        XCTAssertEqual(SignalKTimestampParser.date(from: older), first)
    }
}
