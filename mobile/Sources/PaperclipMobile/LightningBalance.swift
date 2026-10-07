import Foundation
import CoreFoundation

public struct LightningBalance: Equatable, Sendable {
    public let sendableMsat: UInt64
    public let receivableMsat: UInt64
    public let activeChannels: Int

    public static func decode(_ data: Data, implementation: LightningImplementation) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channels = object["channels"] as? [[String: Any]] else { throw ConnectionError.response }
        var send: UInt64 = 0, receive: UInt64 = 0, active = 0
        for channel in channels {
            let outgoing: UInt64, incoming: UInt64
            if implementation == .cln {
                guard channel["state"] as? String == "CHANNELD_NORMAL", channel["peer_connected"] as? Bool == true else { continue }
                outgoing = try amount(channel["spendable_msat"])
                incoming = try amount(channel["receivable_msat"])
            } else {
                guard channel["active"] as? Bool == true else { continue }
                let local = try amount(channel["local_balance"])
                let remote = try amount(channel["remote_balance"])
                let localConstraints = channel["local_constraints"] as? [String: Any]
                let remoteConstraints = channel["remote_constraints"] as? [String: Any]
                let localReserve = try amount(localConstraints?["chan_reserve_sat"] ?? channel["local_chan_reserve_sat"])
                let remoteReserve = try amount(remoteConstraints?["chan_reserve_sat"] ?? channel["remote_chan_reserve_sat"])
                outgoing = try msats(local > localReserve ? local - localReserve : 0)
                incoming = try msats(remote > remoteReserve ? remote - remoteReserve : 0)
            }
            let (nextSend, sendOverflow) = send.addingReportingOverflow(outgoing)
            let (nextReceive, receiveOverflow) = receive.addingReportingOverflow(incoming)
            guard !sendOverflow, !receiveOverflow else { throw ConnectionError.response }
            send = nextSend; receive = nextReceive; active += 1
        }
        return Self(sendableMsat: send, receivableMsat: receive, activeChannels: active)
    }
    private static func amount(_ value: Any?) throws -> UInt64 {
        var text: String
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { throw ConnectionError.response }
            text = number.stringValue
        } else if let string = value as? String { text = string }
        else { throw ConnectionError.response }
        if text.hasSuffix("msat") { text.removeLast(4) }
        guard let result = UInt64(text) else { throw ConnectionError.response }
        return result
    }
    private static func msats(_ sats: UInt64) throws -> UInt64 {
        guard sats <= UInt64.max / 1000 else { throw ConnectionError.response }
        return sats * 1000
    }
}

public struct LightningNodeError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}
