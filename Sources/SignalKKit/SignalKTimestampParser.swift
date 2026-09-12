import Foundation

/// Fast path for the UTC timestamps normally sent by Signal K. Keep the
/// existing formatter fallback for offsets, other precisions and older macOS.
/// Dates are never replaced with arrival time here; that fallback remains with
/// the caller and is evaluated separately for each missing/invalid timestamp.
enum SignalKTimestampParser {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        if #available(iOS 15.0, macOS 12.0, *) {
            // Restrict the fast path to whole seconds or milliseconds. Other
            // precisions retain ISO8601DateFormatter's existing rounding rules.
            let count = string.utf8.count
            if isCanonicalUTC(string) {
                let style = count == 24 ? UTCStyles.fractional : UTCStyles.plain
                if let date = try? style.parse(string) {
                    // Match the legacy formatter's millisecond-to-epoch
                    // conversion exactly, including floating-point rounding.
                    let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
                    return Date(timeIntervalSince1970: milliseconds / 1_000)
                }
            }
        }
        return fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    private static func isCanonicalUTC(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count == 20 || bytes.count == 24,
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58, bytes.last == 90 else { return false }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard (48...57).contains(bytes[index]) else { return nil }
                value = value * 10 + Int(bytes[index] - 48)
            }
            return value
        }
        guard let year = number(0..<4), year > 0,
              let month = number(5..<7), (1...12).contains(month),
              let day = number(8..<10), day > 0,
              let hour = number(11..<13), hour < 24,
              let minute = number(14..<16), minute < 60,
              let second = number(17..<19), second < 60 else { return false }
        let leapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= days[month - 1] else { return false }
        return bytes.count == 20 || (bytes[19] == 46 && number(20..<23) != nil)
    }

    @available(iOS 15.0, macOS 12.0, *)
    private enum UTCStyles {
        static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        static let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    }
}
