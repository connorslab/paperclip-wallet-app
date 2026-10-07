import SwiftUI
import PaperclipMobile

@MainActor final class CoinjoinModel: ObservableObject {
    @Published var snapshot: [String: Any] = [:]
    @Published var pools: [[String: Any]] = []
    @Published var message = "Connect to browse pools. No coins move until you review and sign."
    @Published var busy = false
    @Published var connected = false
    @Published var relayURL = "wss://relay.kilombino.com"
    @Published var useTor = true
    private var walletID = ""
    private var relay: CoinjoinRelay?
    private var outputRelays: [String: CoinjoinRelay] = [:]
    private var loop: Task<Void, Never>?
    private var proxy: String?
    private var attempts: [String: Date] = [:]
    private var announcements: [String: (UInt64, String, [String: Any])] = [:]
    private var subscribed = ""
    private var replay: [[String: Any]] = []
    private var replayBytes = 0
    private var replaying = false
    private var draining = false
    private var generation = UUID()
    var coins: [[String: Any]] { snapshot["coins"] as? [[String: Any]] ?? [] }
    var rounds: [[String: Any]] { snapshot["rounds"] as? [[String: Any]] ?? [] }
    var active: [String: Any]? { rounds.first { $0["active"] as? Bool == true } }
    func start(walletID: String) async {
        guard self.walletID != walletID else { return }
        self.walletID = walletID
        relayURL = UserDefaults.standard.string(forKey: "coinjoin-relay-" + walletID) ?? relayURL
        if UserDefaults.standard.object(forKey: "coinjoin-tor-" + walletID) != nil { useTor = UserDefaults.standard.bool(forKey: "coinjoin-tor-" + walletID) }
        do { snapshot = try await call("coinjoin_status") } catch { message = error.localizedDescription }
    }
    func call(_ op: String, _ fields: [String: Any] = [:]) async throws -> [String: Any] {
        try await NativeWallet.shared.coinjoin(op, walletID: walletID, fields: fields)
    }
    func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { try await work() } catch { message = error.localizedDescription } }
    }
    func action(_ op: String, _ fields: [String: Any] = [:]) async throws {
        snapshot = try await call(op, fields); try await subscribe(); await flush()
    }
    func connect() async throws {
        stop(); let ticket = generation
        if let r = active { relayURL = r["relay"] as? String ?? relayURL; useTor = r["tor"] as? Bool ?? useTor }
        _ = try CoinjoinRelay.endpoint(relayURL)
        message = useTor ? "Starting Tor…" : "Connecting to relay…"
        proxy = useTor ? try await EmbeddedTor.shared.proxy(for: "builtin") : nil
        guard generation == ticket else { return }
        UserDefaults.standard.set(relayURL, forKey: "coinjoin-relay-" + walletID)
        UserDefaults.standard.set(useTor, forKey: "coinjoin-tor-" + walletID)
        let link = CoinjoinRelay()
        link.receive = { [weak self] value in guard self?.generation == ticket else { return }; await self?.receive(value) }
        link.failed = { [weak self] reason in self?.connected = false; self?.message = reason }
        relay = link; try link.connect(url: relayURL, proxy: proxy)
        connected = true
        try await link.send(["REQ", "pools", ["kinds": [32022], "#t": ["kilojoin"], "limit": 500]])
        try await subscribe(); await flush()
        message = "Connected. Keep this page open during a round."
        loop = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5)); guard let self, self.generation == ticket else { return }
                    if !self.connected {
                        // Start outside the timer task: connect cancels the old timer.
                        Task { [weak self] in
                            do { try await self?.connect() } catch { self?.message = error.localizedDescription }
                        }
                        return
                    }
                    if !self.busy {
                        self.snapshot = try await self.call("coinjoin_tick")
                        await self.flush(); try await self.subscribe()
                        if let r = self.active, r["can_broadcast"] as? Bool == true, let id = r["id"] as? String,
                           Date().timeIntervalSince(self.attempts["broadcast-" + id] ?? .distantPast) > 30 {
                            self.attempts["broadcast-" + id] = Date()
                            self.snapshot = try await self.call("coinjoin_broadcast", ["id": id])
                        }
                        ticks += 1
                        if ticks % 6 == 0 { self.snapshot = try await self.call("coinjoin_sync") }
                        if ticks % 12 == 0 { do { try await self.relay?.ping() } catch { self.connected = false; throw error } }
                    }
                } catch { if !Task.isCancelled { self?.message = error.localizedDescription } }
            }
        }
    }
    private func subscribe() async throws {
        guard connected, let r = active, let id = r["id"] as? String, let keys = r["subscriptions"] as? [String] else { return }
        let key = id + ((r["phase"] as? String == "joining") ? "-joining" : "-welcomed")
        guard key != subscribed else { return }
        subscribed = key; replaying = true; replay = []; replayBytes = 0
        try await relay?.send(["REQ", "round", ["kinds": [2023], "#p": keys]])
    }
    private func receive(_ value: [Any]) async {
        guard let type = value.first as? String else { return }
        do {
            if type == "EVENT", value.count == 3, let sub = value[1] as? String, let event = value[2] as? [String: Any] {
                if sub == "pools" {
                    guard let checked = try? await call("coinjoin_pool", ["event": event]), let terms = checked["terms"] as? [String: Any],
                          let id = terms["id"] as? String, let pub = terms["public_key"] as? String,
                          let stamp = checked["created_at"] as? NSNumber, let eventID = checked["event_id"] as? String else { return }
                    let key = pub + id
                    if let old = announcements[key], old.0 > stamp.uint64Value || (old.0 == stamp.uint64Value && old.1 <= eventID) { return }
                    guard announcements.count < 1000 || announcements[key] != nil else { return }
                    announcements[key] = (stamp.uint64Value, eventID, ["terms": terms, "event": event])
                    pools = announcements.values.map { $0.2 }.filter {
                        guard let t = $0["terms"] as? [String: Any] else { return false }
                        return t["state"] as? String == "open" && (t["timeout"] as? NSNumber)?.doubleValue ?? 0 > Date().timeIntervalSince1970 && ((t["peers"] as? Int ?? 0) < (t["max_peers"] as? Int ?? 0))
                    }.sorted { (($0["terms"] as? [String: Any])?["timeout"] as? Int ?? 0) < (($1["terms"] as? [String: Any])?["timeout"] as? Int ?? 0) }
                } else if sub == "round" {
                    if replaying {
                        replayBytes += (try? JSONSerialization.data(withJSONObject: event).count) ?? 0
                        guard replay.count < 20000, replayBytes < 16 * 1024 * 1024 else { throw WalletFailure(message: "Relay history exceeds the safe processing limit.") }
                        replay.append(event)
                    } else { try await process(event); try await subscribe() }
                }
            } else if type == "EOSE", value.count > 1, value[1] as? String == "round" {
                let events = replay.sorted { ($0["created_at"] as? Int ?? 0) < ($1["created_at"] as? Int ?? 0) }
                replay = []; replayBytes = 0; replaying = false
                for event in events { try await process(event) }
                try await subscribe(); await flush()
            } else if type == "OK", value.count >= 3, let id = value[1] as? String {
                if value[2] as? Bool == true { try await acknowledged(id) }
                else { message = "Relay rejected a message. The saved round can be retried; no replacement payment was created." }
            } else if type == "CLOSED" { connected = false; message = "Relay closed a subscription. Reconnecting…" }
        } catch { message = error.localizedDescription }
    }
    private func process(_ event: [String: Any]) async throws {
        guard let id = active?["id"] as? String else { return }
        snapshot = try await call("coinjoin_event", ["id": id, "event": event])
    }
    private func acknowledged(_ eventID: String) async throws {
        guard let r = rounds.first(where: { (($0["outbox"] as? [[String: Any]]) ?? []).contains { ($0["event"] as? [String: Any])?["id"] as? String == eventID } }), let id = r["id"] as? String else { return }
        snapshot = try await call("coinjoin_ack", ["id": id, "event_id": eventID])
        outputRelays.removeValue(forKey: eventID)?.stop()
        try await subscribe()
    }
    private func flush() async {
        guard connected, !draining else { return }; draining = true; defer { draining = false }
        for r in rounds where r["relay"] as? String == relayURL && r["tor"] as? Bool == useTor {
            for item in r["outbox"] as? [[String: Any]] ?? [] {
                guard let event = item["event"] as? [String: Any], let id = event["id"] as? String,
                      Date().timeIntervalSince(attempts[id] ?? .distantPast) > 30 else { continue }
                attempts[id] = Date()
                do {
                    if item["isolated"] as? Bool == true {
                        outputRelays.removeValue(forKey: id)?.stop()
                        let link = CoinjoinRelay(); let ticket = generation
                        link.receive = { [weak self] value in guard self?.generation == ticket else { return }; await self?.receive(value) }
                        link.failed = { [weak self] _ in self?.message = "Output relay interrupted; retrying the same saved message." }
                        try link.connect(url: r["relay"] as? String ?? relayURL, proxy: proxy)
                        outputRelays[id] = link; try await link.send(["EVENT", event])
                    } else { try await relay?.send(["EVENT", event]) }
                } catch { message = error.localizedDescription }
            }
        }
    }
    func stop() {
        generation = UUID(); loop?.cancel(); loop = nil; relay?.stop(); relay = nil
        outputRelays.values.forEach { $0.stop() }; outputRelays = [:]
        connected = false; subscribed = ""; replay = []; replaying = false; attempts = [:]
    }
}
