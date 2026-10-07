import SwiftUI
import PaperclipMobile

struct PendingNodePayment: Codable {
    let invoice: String
    let hash: String
}

// App-wide, read-only reconciliation. Only the explicit payment action may call pay.
@MainActor final class LightningPaymentMonitor: ObservableObject {
    static let shared = LightningPaymentMonitor()
    @Published private(set) var pending: PendingNodePayment?
    @Published private(set) var status = ""
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var completedHash = ""
    private var storageLoaded = false
    private var submitting = false
    private var task: Task<Void, Never>?
    private var node: LightningNode?
    private let pendingAccount = "lightning-pending-v1"

    func load() {
        guard pending == nil else { return }
        do {
            if let data = try WalletKeychain.read(pendingAccount), !data.isEmpty {
                pending = try JSONDecoder().decode(PendingNodePayment.self, from: data)
                status = "Checking the saved payment with your node…"
            }
            storageLoaded = true
        } catch { storageLoaded = false; status = "Could not read the saved payment. Unlock the device and reopen Paperclip." }
    }
    func useNode(_ node: LightningNode) { self.node = node }
    func record(_ attempt: PendingNodePayment) throws {
        guard storageLoaded, pending == nil else { throw WalletFailure(message: "A saved payment must be checked before sending.") }
        try WalletKeychain.save(JSONEncoder().encode(attempt), account: pendingAccount)
        submitting = true
        pending = attempt; status = "Payment in progress. Checking automatically…"; lastChecked = nil
    }
    func submissionFinished() { submitting = false }
    func setForeground(_ active: Bool) {
        task?.cancel(); task = nil
        guard active else { return }
        load()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
    func checkNow() async {
        guard !checking, !submitting, let attempt = pending else { return }
        checking = true; defer { checking = false }
        do {
            if node == nil {
                guard let data = try WalletKeychain.read("lightning-connection-v1") else {
                    throw WalletFailure(message: "Configure the node used for this payment.")
                }
                var connection = try JSONDecoder().decode(LightningConnection.self, from: data)
                if connection.useTor { connection.torProxy = try await EmbeddedTor.shared.proxy(for: connection.torProxy) }
                node = try LightningNode(connection: connection)
            }
            guard let node else { return }
            guard let data = try WalletKeychain.read("lightning-connection-v1") else { return }
            let implementation = try JSONDecoder().decode(LightningConnection.self, from: data).implementation
            let response = try await node.payments(hash: attempt.hash)
            try Task.checkCancellation()
            guard pending?.hash == attempt.hash else { return }
            lastChecked = Date()
            if let terminal = try LightningPaymentState.terminalState(in: response, hash: attempt.hash, implementation: implementation) {
                // Clear durable state first; storage errors must preserve the attempt.
                try WalletKeychain.save(Data(), account: pendingAccount)
                pending = nil; completedHash = attempt.hash
                status = terminal == "succeeded" ? "Payment successful." : "Payment failed. Your node confirmed it did not complete."
            } else {
                status = "Waiting for your node to confirm the outcome. Checking automatically; no payment will be resent."
            }
        } catch is CancellationError {
            // Resume checking when the app becomes active again.
        } catch {
            node = nil
            status = "Unable to confirm yet. Paperclip will check again while open. \(error.localizedDescription)"
        }
    }
}
