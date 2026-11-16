import SwiftUI
import PaperclipMobile

struct BridgePaymentRecord: Codable, Identifiable {
    enum Source: String, Codable, CaseIterable { case ark, node
        var title: String { self == .ark ? "Ark balance · Beta" : "Lightning node" }
    }
    var id: String { quote.hash }
    let target: String
    let quote: BridgeQuote
    let source: Source
    let walletID: String?
    let walletName: String
    let privateAPI: Bool
    let created: Date
    var nodeEndpoint: String?
    var nodeImplementation: String?
    var submitted = false
    var fundingState = "not_sent"
    var bridgeState = "quoted"
    var verifiedSettlement = false
    var preimage: String?
    var canStartAnother: Bool { verifiedSettlement || !submitted || (fundingState == "failed" && ["failed", "aborted", "expired"].contains(bridgeState)) }
}

@MainActor final class LightningBridgeModel: ObservableObject {
    static let shared = LightningBridgeModel()
    @Published private(set) var records: [BridgePaymentRecord] = []
    @Published private(set) var loaded = false
    @Published var error = ""
    @Published var availability: BridgeAvailability?
    @Published private(set) var receiveAvailability: BridgeAvailability?
    @Published private(set) var serviceHealth: [BridgeDirection: BridgeHealth] = [:]
    private var healthRequests: [BridgeDirection: Task<BridgeAvailability?, Never>] = [:]
    private var healthGeneration = 0
    @Published var checking = false
    private var poller: Task<Void, Never>?
    private let account = "lightning-bridge-payments-v1"
    static let keyAccount = "lightning-bridge-api-key-v1"
    var current: BridgePaymentRecord? { records.last }
    func client() throws -> LightningBridge {
        let key = try WalletKeychain.read(Self.keyAccount).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return LightningBridge(apiKey: key)
    }
    var hasPrivateKey: Bool { (try? WalletKeychain.read(Self.keyAccount))?.isEmpty == false }
    func load() {
        guard !loaded else { return }
        do {
            if let data = try WalletKeychain.read(account), !data.isEmpty { records = try JSONDecoder().decode([BridgePaymentRecord].self, from: data) }
            loaded = true
        } catch { self.error = "Could not open saved bridge payments. Unlock the device and try again." }
    }
    private func save(_ next: [BridgePaymentRecord]) throws {
        guard loaded else { throw WalletFailure(message: "Saved bridge payments must be loaded before continuing.") }
        try WalletKeychain.save(JSONEncoder().encode(next), account: account)
        records = next
    }
    func update(_ id: String, _ edit: (inout BridgePaymentRecord) -> Void) throws {
        var next = records
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw BridgeError.invalidQuote }
        edit(&next[index]); try save(next)
    }
    // Main-actor check and durable write happen together, before any payment request.
    func beginSubmission(_ record: BridgePaymentRecord, connection: LightningConnection? = nil) throws {
        guard let latest = current, latest.id == record.id, latest.quote == record.quote,
              !latest.submitted else { throw WalletFailure(message: "This quote changed or already has a payment attempt. Check its status.") }
        try update(record.id) {
            $0.submitted = true; $0.fundingState = "pending"
            $0.nodeEndpoint = connection?.endpoint
            $0.nodeImplementation = connection?.implementation.rawValue
        }
    }
    func record(target: BridgeInvoice, quote: BridgeQuote, source: BridgePaymentRecord.Source, store: WalletStore) throws {
        guard loaded, current?.canStartAnother != false else { throw WalletFailure(message: "Check the current bridge payment before starting another.") }
        guard !records.contains(where: { $0.id == target.hash && $0.submitted }) else {
            throw WalletFailure(message: "This invoice already has a saved payment attempt. Check its status instead of paying again.")
        }
        _ = try quote.validate(target: target)
        let record = BridgePaymentRecord(target: target.text, quote: quote, source: source,
            walletID: source == .ark ? store.walletID : nil,
            walletName: source == .ark ? store.selectedProfile?.name ?? "Ark wallet" : "Connected XBT node",
            privateAPI: hasPrivateKey, created: Date())
        var next = records.filter { $0.id != target.hash }; next.append(record); try save(next)
    }
    func saveKey(_ key: String) throws {
        load(); LightningBridgeReceiveModel.shared.load()
        guard loaded, LightningBridgeReceiveModel.shared.loaded else {
            throw WalletFailure(message: "Load saved bridge requests before changing the connection.")
        }
        guard !records.contains(where: { $0.submitted && !$0.canStartAnother }),
              !LightningBridgeReceiveModel.shared.busy, !LightningBridgeReceiveModel.shared.hasLiveQuote else {
            throw WalletFailure(message: "Finish the current payment before changing bridge access.")
        }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || ((32...512).contains(value.utf8.count) && !value.contains(where: \.isWhitespace)) else {
            throw WalletFailure(message: "Enter the private API key, or leave blank to use the public API.")
        }
        try WalletKeychain.save(Data(value.utf8), account: Self.keyAccount)
        healthGeneration += 1; healthRequests.values.forEach { $0.cancel() }; healthRequests.removeAll()
        serviceHealth = [:]; availability = nil; receiveAvailability = nil
    }
    func refreshAvailability(direction: BridgeDirection = .paySpamcoin) async {
        if let pending = healthRequests[direction] { _ = await pending.value; return }
        guard (serviceHealth[direction] ?? BridgeHealth()).shouldRefresh() else { return }
        let generation = healthGeneration
        serviceHealth[direction] = BridgeHealth(checking: true)
        let request = Task<BridgeAvailability?, Never> { try? await self.client().availability(direction: direction) }
        healthRequests[direction] = request
        let info = await request.value
        guard generation == healthGeneration else { return }
        healthRequests[direction] = nil
        serviceHealth[direction] = BridgeHealth(open: info?.open, checkedAt: Date())
        if direction == .paySpamcoin { availability = info } else { receiveAvailability = info }
    }
    func setForeground(_ active: Bool) {
        poller?.cancel(); poller = nil
        guard active else { return }
        load()
        LightningBridgeReceiveModel.shared.load()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                await LightningBridgeReceiveModel.shared.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    func refreshStatus() async {
        guard loaded, !checking, let record = current, !record.verifiedSettlement else { return }
        checking = true; defer { checking = false }
        do {
            guard hasPrivateKey == record.privateAPI else { throw WalletFailure(message: "Restore the bridge connection used for this payment.") }
            let status = try await client().status(record.quote)
            try Task.checkCancellation()
            var verified = false
            if status.state == "settled" {
                verified = BridgeInvoice.verifies(preimage: status.preimage ?? "", hash: record.id)
            }
            try update(record.id) {
                $0.bridgeState = status.state
                $0.verifiedSettlement = verified
                if verified { $0.preimage = status.preimage }
            }
            error = status.state == "settled" && !verified ? "The bridge reports settlement; payment proof is unavailable. Check the recipient before any further attempt." : ""
        } catch is CancellationError {} catch { self.error = "Status unavailable. Your saved payment has not been resent. " + error.localizedDescription }
    }
}
