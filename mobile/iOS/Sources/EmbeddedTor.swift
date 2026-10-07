import SwiftUI
import PaperclipMobile
import TorRuntime
import Network

/// One Tor client per app process. Selected routes remain proxied if Tor becomes unavailable.
@MainActor final class EmbeddedTor: ObservableObject {
    static let shared = EmbeddedTor()
    @Published private(set) var status = "Tor starts when you connect."
    private var thread: TorThread?
    private var configuration: TorConfiguration?
    private var controller: TorController?
    private var authenticated = false
    private var authenticationPending = false
    private var socksEndpoint: String?
    private var circuitReady = false
    private var startup: Task<String, Error>?

    func proxy(for selection: String) async throws -> String {
        if selection != "builtin" {
            _ = try EndpointPolicy.proxy(selection)
            return selection
        }
        if let startup { return try await startup.value }
        let task = Task { try await self.bootstrap() }
        startup = task
        defer { startup = nil }
        return try await task.value
    }

    private func bootstrap() async throws -> String {
        if thread == nil {
            var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tor", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let config = TorConfiguration()
            config.dataDirectory = directory
            config.cookieAuthentication = true
            config.autoControlPort = true
            config.ignoreMissingTorrc = true
            config.clientOnly = true
            config.avoidDiskWrites = true
            config.options = ["SocksPort": "auto IsolateSOCKSAuth", "SafeSocks": "1", "Log": "notice stdout"]
            configuration = config
            let worker = TorThread(configuration: config)
            worker.stackSize = 8 * 1024 * 1024
            thread = worker
            worker.start()
        }
        status = "Connecting to Tor…"
        circuitReady = false
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            if thread?.isFinished == true {
                status = "Tor stopped. Restart Paperclip to reconnect."
                throw WalletFailure(message: status)
            }
            if controller?.isConnected != true {
                authenticated = false; authenticationPending = false
                if let file = configuration?.controlPortFile,
                   let contents = try? String(contentsOf: file, encoding: .utf8),
                   contents.hasPrefix("PORT="),
                   let address = URL(string: "tcp://" + contents.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)),
                   address.host == "127.0.0.1", let port = address.port, (1...65535).contains(port) {
                    // The upstream initializer already attempts the connection.
                    let control = TorController(socketHost: "127.0.0.1", port: UInt16(port))
                    if control.isConnected { controller = control }
                }
            }
            if let control = controller, control.isConnected {
                if !authenticated && !authenticationPending, let cookie = configuration?.cookie {
                    authenticationPending = true
                    control.authenticate(with: cookie) { [weak self] success, _ in
                        Task { @MainActor in
                            self?.authenticationPending = false
                            self?.authenticated = success
                        }
                    }
                }
                if authenticated {
                    control.getInfoForKeys(["status/circuit-established", "net/listeners/socks", "status/bootstrap-phase"]) { [weak self] values in
                        Task { @MainActor in
                            guard let self, values.count == 3 else { return }
                            self.circuitReady = values[0] == "1"
                            let listener = values[1].split(separator: " ").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
                            if let url = URL(string: "socks5h://" + listener), url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port) {
                                self.socksEndpoint = url.absoluteString
                            }
                            if let progress = values[2].split(separator: " ").first(where: { $0.hasPrefix("PROGRESS=") }) {
                                self.status = "Connecting to Tor · \(progress.dropFirst(9))%"
                            }
                        }
                    }
                }
            }
            if circuitReady, let endpoint = socksEndpoint {
                status = "Tor connected"
                return endpoint
            }
            try await Task.sleep(for: .seconds(1))
        }
        status = "Tor could not connect. Check your network and retry."
        throw WalletFailure(message: status)
    }
}

struct TorProxyPicker: View {
    @Binding var selection: String
    @ObservedObject private var tor = EmbeddedTor.shared
    var body: some View {
        Picker("Tor connection", selection: Binding(
            get: { selection == "builtin" },
            set: { selection = $0 ? "builtin" : "socks5h://127.0.0.1:9050" }
        )) {
            Text("Built-in Tor").tag(true)
            Text("External SOCKS proxy").tag(false)
        }
        if selection == "builtin" {
            Text(tor.status).font(.caption).accessibilityIdentifier("tor-status")
        } else {
            TextField("socks5h://proxy-host:port", text: $selection)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Text("Use the SOCKS proxy address here, not the node's .onion URL. Select Built-in Tor if you do not run a separate proxy.").font(.caption)
        }
    }
}

#if DEBUG
// A launch-only device smoke test. It never loads wallet keys or node credentials.
enum TorProbe {
    @MainActor static func run() async {
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tor-probe.txt")
        try? "Starting".write(to: output, atomically: true, encoding: .utf8)
        do {
            let endpoint = try await EmbeddedTor.shared.proxy(for: "builtin")
            let url = try EndpointPolicy.proxy(endpoint)
            let configuration = URLSessionConfiguration.ephemeral
            var proxy = Network.ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(url.host!), port: .init(rawValue: UInt16(url.port!))!))
            proxy.allowFailover = false
            configuration.proxyConfigurations = [proxy]
            configuration.timeoutIntervalForRequest = 45
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: URL(string: "https://check.torproject.org/api/ip")!)
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (response as? HTTPURLResponse)?.statusCode == 200, result?["IsTor"] as? Bool == true else {
                throw WalletFailure(message: "Tor exit verification failed")
            }
            try "PASS: embedded Tor bootstrapped; URLSession request verified as Tor traffic.".write(to: output, atomically: true, encoding: .utf8)
        } catch {
            try? "FAIL: \(error.localizedDescription)".write(to: output, atomically: true, encoding: .utf8)
        }
    }
}
#endif
