import SwiftUI
import PaperclipMobile
import TorRuntime
import Network

/// One Tor runtime per process; each failed attempt gets a fresh control connection.
@MainActor final class EmbeddedTor: ObservableObject {
    static let shared = EmbeddedTor()
    @Published private(set) var status = "Tor starts when you connect."
    private var thread: TorThread?
    private var configuration: TorConfiguration?
    private var controller: TorController?
    private var startup: Task<String, Error>?
    private var attempt: UUID?
    private var authenticated = false
    private var authenticationPending = false
    private var infoPending = false
    private var snapshot: TorStartupSnapshot?
    private var controlFailure: String?
    private var lastDiagnostic = ""
    private var lastProgress: Int?

    // Only fixed stages, booleans, percentages, numeric errors and public certificate hashes belong here.
    // Never record control messages, cookies, URLs, node responses or credentials.
    func diagnostic(_ event: String) {
        guard event != lastDiagnostic else { return }
        lastDiagnostic = event
        #if DEBUG
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tor-diagnostics.txt")
        var data = (try? Data(contentsOf: output)) ?? Data()
        if data.count > 32_768 { data = Data() }
        data.append(Data("\(Date().timeIntervalSince1970): \(event)\n".utf8))
        try? data.write(to: output, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }

    func proxy(for selection: String) async throws -> String {
        try Task.checkCancellation()
        if selection != "builtin" { _ = try EndpointPolicy.proxy(selection); return selection }
        if let startup { return try await TorStartupWaiter.value(of: startup) }
        let task = Task {
            defer { self.startup = nil }
            return try await self.bootstrap()
        }
        startup = task
        return try await TorStartupWaiter.value(of: task)
    }

    private func startRuntime() throws {
        guard thread == nil else { return }
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            .posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let config = TorConfiguration()
        config.dataDirectory = directory
        config.cookieAuthentication = true; config.autoControlPort = true
        config.ignoreMissingTorrc = true; config.clientOnly = true; config.avoidDiskWrites = true
        config.options = ["SocksPort": "auto IsolateSOCKSAuth", "SafeSocks": "1", "SafeLogging": "1", "Log": "err stdout"]
        // A previous process's port and cookie must never be used for the new runtime.
        for name in ["controlport", "control_auth_cookie"] {
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        configuration = config
        let worker = TorThread(configuration: config)
        worker.stackSize = 8 * 1024 * 1024
        thread = worker; worker.start()
        diagnostic("runtime started; directory protection=after-first-unlock")
    }

    private func bootstrap() async throws -> String {
        let id = UUID(); attempt = id
        var succeeded = false
        defer {
            attempt = nil // Ignore late callbacks from completed/timed-out attempts.
            if !succeeded { controller?.close(); controller = nil }
        }
        controller?.close(); controller = nil
        authenticated = false; authenticationPending = false; infoPending = false
        snapshot = nil; controlFailure = nil; lastProgress = nil
        let clock = ContinuousClock()
        let began = clock.now
        var phaseBegan = began, requestBegan = began, lastPoll = began - .seconds(1)
        var stage = TorStartupStage.controlFile
        func show(_ next: TorStartupStage) {
            if stage != next {
                phaseBegan = clock.now; stage = next
                diagnostic("stage=\(next.rawValue)")
            }
            status = next.message
        }
        do {
            show(.controlFile)
            try startRuntime()
            while clock.now - began < .seconds(180) {
                try Task.checkCancellation()
                if thread?.isFinished == true { throw WalletFailure(message: "Tor stopped unexpectedly. Restart Paperclip to reconnect.") }
                if let failure = controlFailure { throw WalletFailure(message: failure) }
                if let control = controller, !control.isConnected {
                    throw WalletFailure(message: "Tor’s local control connection closed. Retry the connection.")
                }
                if controller == nil {
                    if let file = configuration?.controlPortFile,
                       let contents = try? String(contentsOf: file, encoding: .utf8),
                       let port = TorStartupSnapshot.controlPort(contents) {
                        show(.controlConnection)
                        let control = TorController(socketHost: "127.0.0.1", port: port)
                        if control.isConnected { controller = control; show(.cookie) }
                    }
                }
                if let control = controller {
                    if !authenticated && !authenticationPending, let cookie = configuration?.cookie, cookie.count == 32 {
                        show(.authentication); authenticationPending = true; requestBegan = clock.now
                        control.authenticate(with: cookie) { [weak self] success, _ in
                            Task { @MainActor in
                                guard let self, self.attempt == id else { return }
                                self.authenticationPending = false; self.authenticated = success
                                self.diagnostic("control authentication=\(success)")
                                if !success { self.controlFailure = "Tor rejected local controller authentication. Retry the connection." }
                            }
                        }
                    }
                    if authenticated {
                        if let current = snapshot, !infoPending {
                            if current.circuitReady, let endpoint = current.socksEndpoint {
                                status = "Tor connected"; diagnostic("Tor ready")
                                succeeded = true
                                return endpoint
                            }
                            if current.circuitReady { show(.socks) }
                            else if current.progress == 100 { show(.circuit) }
                            else {
                                show(.bootstrap)
                                if let progress = current.progress {
                                    status = "Connecting to Tor · \(progress)%"
                                    if progress != lastProgress { diagnostic("bootstrap progress=\(progress)"); lastProgress = progress }
                                }
                            }
                        }
                        if !infoPending, clock.now - lastPoll >= .seconds(1) {
                            if snapshot == nil { show(.statusReply) }
                            infoPending = true; requestBegan = clock.now; lastPoll = clock.now
                            control.getInfoForKeys(["status/circuit-established", "net/listeners/socks", "status/bootstrap-phase"]) { [weak self] values in
                                Task { @MainActor in
                                    guard let self, self.attempt == id else { return }
                                    self.infoPending = false
                                    guard let parsed = TorStartupSnapshot(values: values) else {
                                        self.controlFailure = "Tor returned an invalid startup status. Retry the connection."; return
                                    }
                                    self.snapshot = parsed
                                }
                            }
                        }
                    }
                }
                // A listening control socket can precede readiness to answer commands.
                // Live cached-start testing took 14s before even an independent controller
                // received AUTHENTICATE. Keep startup bounded, but allow initialization.
                let replyTimeout: Duration = authenticationPending ? .seconds(45) : .seconds(10)
                if authenticationPending, clock.now - requestBegan > .seconds(10) {
                    status = "Tor is starting · waiting for its local controller…"
                }
                if (authenticationPending || infoPending), clock.now - requestBegan > replyTimeout {
                    throw WalletFailure(message: (infoPending ? TorStartupStage.statusReply : .authentication).timeoutMessage)
                }
                if [.controlFile, .controlConnection, .cookie, .socks].contains(stage), clock.now - phaseBegan > .seconds(15) {
                    throw WalletFailure(message: stage.timeoutMessage)
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-tor-retry-probe"), !TorProbe.didInjectFailure {
                    TorProbe.didInjectFailure = true
                    throw WalletFailure(message: "Diagnostic interruption before Tor readiness. Retry the connection.")
                }
                #endif
                try await Task.sleep(for: .milliseconds(200))
            }
            throw WalletFailure(message: stage.timeoutMessage)
        } catch {
            let message = error is CancellationError ? "Tor startup was cancelled. Retry the connection." :
                (error as? WalletFailure)?.message ?? "Tor could not access its local startup files. Unlock your iPhone and retry."
            status = message; diagnostic("startup failed stage=\(stage.rawValue)")
            throw WalletFailure(message: message)
        }
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
// Launch-only Tor smoke test. It does not load wallet keys or node credentials.
enum TorProbe {
    @MainActor static var didInjectFailure = false
    @MainActor static func run() async {
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tor-probe.txt")
        try? "Starting".write(to: output, atomically: true, encoding: .utf8)
        do {
            if ProcessInfo.processInfo.arguments.contains("-tor-retry-probe") {
                do { _ = try await EmbeddedTor.shared.proxy(for: "builtin") }
                catch { EmbeddedTor.shared.diagnostic("Expected injected startup failure completed") }
            }
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

#if DEBUG && targetEnvironment(simulator)
/// Explicit opt-in, read-only live check. Inputs stay in the simulator sandbox;
/// reports contain stages/codes only, never node responses or credentials.
enum NodeReadProbe {
    struct Input: Decodable { let cases: [Case] }
    struct Case: Decodable {
        let label: String
        let connection: LightningConnection
        let expectedIdentity: String
    }
    @MainActor static func run() async {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let input = directory.appendingPathComponent("node-read-probe.json")
        let output = directory.appendingPathComponent("node-read-probe-results.json")
        var reports = [[String: String]]()
        func record(_ label: String, _ stage: String, _ result: String) {
            reports.append(["case": label, "stage": stage, "result": result])
            if let data = try? JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output, options: [.atomic, .completeFileProtection])
            }
        }
        do {
            let cases = try JSONDecoder().decode(Input.self, from: Data(contentsOf: input)).cases
            if cases.contains(where: { $0.connection.useTor }) {
                var returned = false
                let task = Task { @MainActor in
                    defer { returned = true }
                    return try await EmbeddedTor.shared.proxy(for: "builtin")
                }
                try await Task.sleep(for: .milliseconds(100))
                task.cancel()
                try await Task.sleep(for: .milliseconds(300))
                record("tor", "cancel-within-300ms", returned ? "returned" : "STILL WAITING")
                _ = await task.result
            }
            for item in cases {
                let label = item.connection.implementation.rawValue + (item.connection.useTor ? "-tor" : "-lan")
                var connection = item.connection
                record(label, "start", "running")
                do {
                    if connection.useTor {
                        connection.torProxy = try await EmbeddedTor.shared.proxy(for: connection.torProxy)
                        record(label, "embedded-tor", "ready")
                    }
                    let node = try LightningNode(connection: connection, diagnostics: { event in
                        Task { @MainActor in EmbeddedTor.shared.diagnostic("Read probe transport \(event)") }
                    })
                    for attempt in 1...3 {
                        let began = Date()
                        let info = try JSONSerialization.jsonObject(with: await node.info()) as? [String: Any] ?? [:]
                        guard info[connection.implementation == .cln ? "id" : "identity_pubkey"] as? String == item.expectedIdentity else {
                            record(label, "identity", "mismatch"); break
                        }
                        _ = try LightningNetwork.decode(info, implementation: connection.implementation)
                        record(label, "getinfo-\(attempt)", "verified \(Int(Date().timeIntervalSince(began) * 1000))ms")
                        _ = try await node.balance()
                        record(label, "balance-\(attempt)", "decoded")
                    }
                    var rejected = connection
                    rejected.certificateSHA256 = String(repeating: "0", count: 64)
                    do {
                        _ = try await LightningNode(connection: rejected).info()
                        record(label, "wrong-pin", "FAIL accepted")
                    } catch LightningTLSFailure.pinMismatch { record(label, "wrong-pin", "rejected") }
                    catch { record(label, "wrong-pin", "other error \((error as NSError).code)") }
                    _ = try await node.info()
                    record(label, "after-pin-failure", "reconnected")
                } catch {
                    record(label, "failure", "\(String(describing: type(of: error))) code=\((error as NSError).code)")
                }
            }
            record("probe", "complete", "finished")
        } catch { record("probe", "input", "unavailable or invalid") }
    }
}
#endif
