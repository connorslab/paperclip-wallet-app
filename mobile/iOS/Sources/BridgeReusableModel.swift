import SwiftUI
import Security
import PaperclipMobile

struct ReusableBridgeRecord: Codable, Identifiable {
    let id: UUID
    let token: String
    let destination: String?
    let receiveXBT: Bool?
    let created: Date
    var binding: BridgeReusableOffer?
    var revocationRequested = false
}

@MainActor final class BridgeReusableModel: ObservableObject {
    static let shared = BridgeReusableModel()
    @Published private(set) var records: [ReusableBridgeRecord] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var message = ""
    @Published private(set) var available: Bool?
    private let account = "bridge-reusable-offers-v1"
    private let api = LightningBridge()
    func load() {
        guard !loaded else { return }
        do {
            let rows = try WalletKeychain.read(account).map { try JSONDecoder().decode([ReusableBridgeRecord].self, from: $0) } ?? []
            guard rows.count <= 100, Set(rows.map(\.id)).count == rows.count, Set(rows.map(\.token)).count == rows.count else { throw BridgeError.invalidQuote }
            for row in rows {
                guard BridgeReusableOffer.validToken(row.token), (row.destination == nil) == (row.receiveXBT == nil) else { throw BridgeError.invalidQuote }
                if let destination = row.destination, let xbt = row.receiveXBT { try BridgeReusableOffer.validateOffer(destination, xbt: xbt, now: 0) }
                try row.binding?.validate()
                if let binding = row.binding, let xbt = row.receiveXBT { guard binding.direction.targetIsXBT == xbt else { throw BridgeError.invalidQuote } }
            }
            records = rows; loaded = true
        } catch { message = "Saved offers could not be loaded. Unlock your device and try again; do not create replacements." }
    }
    private func save(_ row: ReusableBridgeRecord) throws {
        guard loaded else { throw BridgeError.invalidQuote }
        var next = records
        if let index = next.firstIndex(where: { $0.id == row.id }) { next[index] = row }
        else { guard next.count < 100 else { throw BridgeError.unavailable("Offer storage is full. Keep your existing management keys.") }; next.append(row) }
        try WalletKeychain.save(JSONEncoder().encode(next), account: account); records = next
    }
    func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy, loaded else { return }; busy = true; message = ""
        Task { defer { busy = false }; do { try await work() } catch { message = "Request not confirmed. Your saved key and request are preserved. Check status before creating a replacement." } }
    }
    func health() async { available = try? await api.reusableAvailable() }
    func create(destination: String, receiveXBT: Bool) async throws -> UUID {
        let input = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        try BridgeReusableOffer.validateOffer(input, xbt: receiveXBT)
        let text = input.lowercased()
        if let existing = records.first(where: { $0.destination == text && $0.receiveXBT == receiveXBT && $0.binding?.revoked != true }) {
            try await update(existing, action: existing.binding == nil ? "register" : "lookup"); return existing.id
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw BridgeError.invalidQuote }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let row = ReusableBridgeRecord(id: UUID(), token: token, destination: text, receiveXBT: receiveXBT, created: Date())
        try save(row) // Durable management key and immutable recipient BEFORE registering.
        try await update(row, action: "register"); return row.id
    }
    func restore(_ token: String) async throws -> UUID {
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard BridgeReusableOffer.validToken(key) else { throw BridgeError.invalidQuote }
        let row = records.first { $0.token == key } ?? ReusableBridgeRecord(id: UUID(), token: key, destination: nil, receiveXBT: nil, created: Date())
        try save(row); try await update(row, action: "lookup"); return row.id
    }
    func update(_ row: ReusableBridgeRecord, action: String) async throws {
        var next = records.first { $0.id == row.id } ?? row
        if action == "revoke" { next.revocationRequested = true; try save(next) }
        guard !(action == "register" && next.revocationRequested) else { throw BridgeError.invalidQuote }
        let binding = try await api.reusable(action, token: next.token, destination: next.destination, receiveXBT: next.receiveXBT)
        guard next.receiveXBT.map({ $0 == binding.direction.targetIsXBT }) ?? true,
              next.binding.map({ $0.offer == binding.offer && $0.direction == binding.direction && (!$0.revoked || binding.revoked) }) ?? true else { throw BridgeError.invalidQuote }
        next.binding = binding; try save(next)
        message = binding.revoked ? "Offer revoked. In-flight payments can still finish or refund." : "Offer saved. Creating an offer does not confirm a payment."
    }
}
