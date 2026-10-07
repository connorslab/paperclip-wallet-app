import Foundation
import Network
import PaperclipMobile

/// Each connection is ephemeral. Output posts use fresh SOCKS credentials and a separate session.
@MainActor final class CoinjoinRelay {
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var lastHeard = Date()
    var receive: (([Any]) async -> Void)?
    var failed: ((String) -> Void)?
    static func endpoint(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "wss", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw WalletFailure(message: "Use a wss:// relay URL without credentials, query, or fragment.")
        }
        return url
    }
    func connect(url: String, proxy: String?) throws {
        stop()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 86400
        if let proxy {
            let address = try EndpointPolicy.proxy(proxy)
            guard let host = address.host, let port = address.port, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw ConnectionError.invalidEndpoint }
            var socks = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(host), port: nwPort))
            socks.allowFailover = false
            socks.applyCredential(username: UUID().uuidString, password: UUID().uuidString)
            config.proxyConfigurations = [socks]
        }
        let session = URLSession(configuration: config, delegate: NoRelayRedirect(), delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: try Self.endpoint(url)); socket.maximumMessageSize = 524288
        self.socket = socket; lastHeard = Date(); socket.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: continue }
                    guard data.count <= 524288, let array = try JSONSerialization.jsonObject(with: data) as? [Any] else { continue }
                    self?.lastHeard = Date()
                    await self?.receive?(array)
                }
            } catch { if !Task.isCancelled { self?.failed?("Relay disconnected. Reconnect to resume the saved round.") } }
        }
    }
    func send(_ value: [Any]) async throws {
        guard let socket else { throw WalletFailure(message: "Connect the relay first.") }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 524288, let text = String(data: data, encoding: .utf8) else { throw ConnectionError.response }
        try await socket.send(.string(text))
    }
    func ping() async throws {
        guard let socket, Date().timeIntervalSince(lastHeard) < 120 else { throw WalletFailure(message: "Relay timed out.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        }
        lastHeard = Date()
    }
    func stop() { reader?.cancel(); reader = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil; session?.invalidateAndCancel(); session = nil }
}
private final class NoRelayRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
