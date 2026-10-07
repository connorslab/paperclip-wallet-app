import Foundation

public struct ActivityItem: Identifiable {
    public let id: String
    public let title: String
    public let status: String
    public let amountSat: Int64
    public let detail: String
    public let date: Date?

    public init(id: String, title: String, status: String, amountSat: Int64, detail: String, date: Date? = nil) {
        self.id = id; self.title = title; self.status = status
        self.amountSat = amountSat; self.detail = detail; self.date = date
    }

    public static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public static func unixDate(_ seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public static func newestFirst(_ items: [Self]) -> [Self] {
        items.sorted {
            let left = $0.date ?? .distantPast, right = $1.date ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
    }
}
