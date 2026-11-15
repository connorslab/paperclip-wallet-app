import Foundation

public struct TorStartupSnapshot: Equatable, Sendable {
    public let circuitReady: Bool
    public let socksEndpoint: String?
    public let progress: Int?
    public init?(values: [String]) {
        guard values.count == 3, ["0", "1"].contains(values[0]) else { return nil }
        circuitReady = values[0] == "1"
        socksEndpoint = values[1].split(separator: " ").compactMap { token -> String? in
            let address = token.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let port = Self.loopbackPort(address) else { return nil }
            return "socks5h://127.0.0.1:\(port)"
        }.first
        progress = values[2].split(separator: " ").first(where: { $0.hasPrefix("PROGRESS=") })
            .flatMap { Int($0.dropFirst(9)) }.flatMap { (0...100).contains($0) ? $0 : nil }
    }
    public static func controlPort(_ contents: String) -> UInt16? {
        guard contents.hasPrefix("PORT=") else { return nil }
        return loopbackPort(String(contents.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private static func loopbackPort(_ address: String) -> UInt16? {
        let pieces = address.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0] == "127.0.0.1", !pieces[1].isEmpty,
              pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = UInt16(pieces[1]), port > 0 else { return nil }
        return port
    }
}

public enum TorStartupStage: String, Sendable {
    case controlFile, controlConnection, cookie, authentication, statusReply, bootstrap, circuit, socks
    public var message: String {
        switch self {
        case .controlFile: return "Starting Tor · waiting for local control port…"
        case .controlConnection: return "Tor started · opening local control connection…"
        case .cookie: return "Tor started · waiting for local authentication…"
        case .authentication: return "Tor started · authenticating local controller…"
        case .statusReply: return "Tor started · checking bootstrap status…"
        case .bootstrap: return "Connecting to the Tor network…"
        case .circuit: return "Tor bootstrapped · waiting for a usable circuit…"
        case .socks: return "Tor circuit ready · waiting for local proxy…"
        }
    }
    public var timeoutMessage: String {
        switch self {
        case .controlFile: return "Tor did not publish its local control port. Keep Paperclip open and retry."
        case .controlConnection: return "Tor’s local control connection did not open. Retry the connection."
        case .cookie: return "Tor’s local authentication file is unavailable. Unlock your iPhone and retry."
        case .authentication: return "Tor did not answer local authentication. Retry the connection."
        case .statusReply: return "Tor stopped answering startup status requests. Retry the connection."
        case .bootstrap, .circuit: return "Tor could not establish a circuit on this network. Keep Paperclip open and retry, or try another network."
        case .socks: return "Tor did not provide a valid local SOCKS listener. Retry the connection."
        }
    }
}

/// Cancelling one connection must stop waiting promptly without stopping Tor
/// for other consumers (node reads, wallet sync, or a subsequent retry).
public enum TorStartupWaiter {
    public static func value(of startup: Task<String, Error>) async throws -> String {
        try Task.checkCancellation()
        let updates = AsyncThrowingStream<String, Error> { continuation in
            let observer = Task {
                do {
                    continuation.yield(try await startup.value)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in observer.cancel() }
        }
        for try await endpoint in updates {
            try Task.checkCancellation()
            return endpoint
        }
        throw CancellationError()
    }
}
