import SwiftUI
import PaperclipMobile

struct BridgeReceiveRecord: Codable, Identifiable {
    var id: String { target.hash }
    let target: BridgeInvoice
    var invoice: String { target.text }
    let nodeEndpoint: String
    let implementation: LightningImplementation
    let created: Date
    var quote: BridgeQuote?
    var privateAPI = false
    var bridgeState = "quoted"
    var nodeState = "waiting"
    var received: Bool { nodeState == "paid" }
    var finished: Bool { received || nodeState == "ended" || ["failed", "aborted", "expired"].contains(bridgeState) }
}

@MainActor final class LightningBridgeReceiveModel: ObservableObject {
    static let shared = LightningBridgeReceiveModel()
    @Published private(set) var records: [BridgeReceiveRecord] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var error = ""
    private let account = "lightning-bridge-receives-v1"
    private var checking = false
    var current: BridgeReceiveRecord? { records.last }
    var hasLiveQuote: Bool { records.contains { $0.quote != nil && !$0.finished } }
    func load() {
        guard !loaded else { return }
        do {
            let saved = try WalletKeychain.read(account).map { try JSONDecoder().decode([BridgeReceiveRecord].self, from: $0) } ?? []
            for record in saved {
                let invoice = try BridgeInvoice(record.invoice)
                guard invoice.isXBT else { throw BridgeError.invalidInvoice }
            }
            records = saved; loaded = true
        } catch { self.error = "Saved bridge receive requests could not be loaded. Unlock your device and try again." }
    }
    func save(_ record: BridgeReceiveRecord) throws {
        guard loaded else { throw WalletFailure(message: "Load saved receive requests first.") }
        var next = records
        if let index = next.firstIndex(where: { $0.id == record.id }) { next[index] = record } else { next.append(record) }
        try WalletKeychain.save(JSONEncoder().encode(next), account: account); records = next
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = ""
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
    func connection() throws -> LightningConnection {
        guard let data = try WalletKeychain.read("lightning-connection-v1") else { throw WalletFailure(message: "Connect an XBT Core Lightning or LND node first.") }
        return try JSONDecoder().decode(LightningConnection.self, from: data)
    }
    func node(_ saved: LightningConnection) async throws -> LightningNode {
        var resolved = saved
        if saved.useTor { resolved.torProxy = try await EmbeddedTor.shared.proxy(for: saved.torProxy) }
        return try LightningNode(connection: resolved)
    }
    func create(amount: UInt64) async throws {
        guard loaded, current == nil || current?.finished == true || current?.quote == nil else {
            throw WalletFailure(message: "Finish the current receive request first.")
        }
        let saved = try connection(), client = try await node(saved)
        let info = try JSONSerialization.jsonObject(with: await client.info()) as? [String: Any] ?? [:]
        guard try LightningNetwork.decode(info, implementation: saved.implementation) == .mainnet else {
            throw WalletFailure(message: "Receive through the bridge requires an XBT mainnet node.")
        }
        let value = try await client.invoice(amount: amount), invoice = try BridgeInvoice(value)
        try invoice.validateTarget(direction: .receiveXBT)
        guard amount <= 2_100_000_000_000_000, invoice.msat == amount * 1000, try connection() == saved else { throw BridgeError.invalidInvoice }
        // Only invoices issued by the connected node are accepted. Never import an
        // arbitrary XBT invoice here, which could be an unsupported Ark invoice.
        let receipt: LightningInvoiceReceipt
        do { receipt = try await client.receivedInvoice(invoice) }
        catch { throw WalletFailure(message: "The node invoice could not be checked. Allow invoice reads in your CLN rune or LND macaroon, then try again.") }
        guard receipt.state == .waiting else { throw BridgeError.invalidInvoice }
        try save(BridgeReceiveRecord(target: invoice, nodeEndpoint: saved.endpoint,
            implementation: saved.implementation, created: Date()))
    }
    func makeQuote(_ record: BridgeReceiveRecord) async throws {
        guard current?.id == record.id, current?.quote == nil else { throw BridgeError.invalidQuote }
        try record.target.validateTarget(direction: .receiveXBT)
        let connection = try connection()
        guard connection.endpoint == record.nodeEndpoint, connection.implementation == record.implementation else {
            throw WalletFailure(message: "Reconnect the original node before continuing.")
        }
        let client = try await node(connection)
        guard try await client.receivedInvoice(record.target).state == .waiting else {
            throw WalletFailure(message: "This node invoice is no longer unpaid. Create a new receive request.")
        }
        let api = try LightningBridgeModel.shared.client()
        let privateAPI = LightningBridgeModel.shared.hasPrivateKey
        let quote = try await api.quote(record.target, direction: .receiveXBT)
        _ = try quote.validate(target: record.target, direction: .receiveXBT)
        guard current?.id == record.id, current?.quote == nil else { throw BridgeError.invalidQuote }
        var updated = current!; updated.quote = quote; updated.privateAPI = privateAPI
        // Persist before exposing the shareable invoice.
        try save(updated)
    }
    func refresh(id: String? = nil) async {
        let selected = id.flatMap { wanted in records.first { $0.id == wanted } } ?? current
        guard loaded, !checking, !busy, let record = selected, !record.received, record.quote != nil else { return }
        checking = true; defer { checking = false }
        var bridgeState: String?
        var nodeState: String?
        var issues: [String] = []
        do {
            guard LightningBridgeModel.shared.hasPrivateKey == record.privateAPI else { throw WalletFailure(message: "Restore the bridge connection used for this request.") }
            bridgeState = try await LightningBridgeModel.shared.client().status(record.quote!).state
        } catch { issues.append("Bridge status unavailable.") }
        do {
            let saved = try connection()
            guard saved.endpoint == record.nodeEndpoint, saved.implementation == record.implementation else {
                throw WalletFailure(message: "Reconnect the original XBT node to confirm receipt.")
            }
            let client = try await node(saved)
            nodeState = try await client.receivedInvoice(record.target).state.rawValue
        } catch { issues.append("Node receipt is not confirmed. Check the original node connection and invoice-read permission.") }
        guard !Task.isCancelled, let latest = records.first(where: { $0.id == record.id }) else { return }
        var updated = latest
        if let bridgeState { updated.bridgeState = bridgeState }
        if let nodeState { updated.nodeState = nodeState }
        do { try save(updated); error = issues.joined(separator: " ") }
        catch { self.error = "Could not save the latest receive status. Check your node before making another request." }
    }
}
