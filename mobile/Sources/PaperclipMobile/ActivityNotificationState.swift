import Foundation

/// Keep a baseline so enabling alerts or opening an existing wallet does not announce its history.
public struct ActivityNotificationState: Codable {
    public private(set) var observed: [String: String] = [:]
    public private(set) var initialized = false
    private var baselineDate: Date?
    public init() {}
    public mutating func changes(_ items: [ActivityItem]) -> [ActivityItem] {
        var changes: [ActivityItem] = []
        for item in items {
            let status = item.status.lowercased()
            let historical = observed[item.id] == nil && item.date.map { $0 < (baselineDate ?? .distantPast) } == true
            if initialized, !historical, item.amountSat != 0, observed[item.id] != status {
                changes.append(item)
            }
            observed[item.id] = status
        }
        if !initialized { baselineDate = Date() }
        initialized = true
        return changes
    }
}
