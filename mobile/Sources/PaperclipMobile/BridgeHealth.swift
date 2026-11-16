import Foundation

/// Service availability is independent of any saved payment's settlement.
public enum BridgeHealthState: String, Sendable {
    case checking, live, paused, unknown, limited
    public var title: String {
        switch self {
        case .checking: return "Checking"
        case .live: return "Live"
        case .paused: return "Paused"
        case .unknown: return "Status unknown"
        case .limited: return "Limited"
        }
    }
    public static func combined(_ pay: Self, _ receive: Self) -> Self {
        if pay == receive { return pay }
        if pay == .checking || receive == .checking { return .checking }
        if pay == .unknown || receive == .unknown { return .unknown }
        return .limited
    }
}

public struct BridgeHealth: Sendable {
    public let open: Bool?
    public let checkedAt: Date?
    public let checking: Bool
    public init(open: Bool? = nil, checkedAt: Date? = nil, checking: Bool = false) {
        self.open = open; self.checkedAt = checkedAt; self.checking = checking
    }
    public func state(now: Date = Date()) -> BridgeHealthState {
        if checking { return .checking }
        guard let checkedAt, let open, (0..<90).contains(now.timeIntervalSince(checkedAt)) else { return .unknown }
        return open ? .live : .paused
    }
    public func shouldRefresh(now: Date = Date()) -> Bool {
        guard !checking else { return false }
        guard let checkedAt else { return true }
        return !(0..<30).contains(now.timeIntervalSince(checkedAt))
    }
}
