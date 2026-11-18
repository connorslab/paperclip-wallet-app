import SwiftUI
import PaperclipMobile

// App-wide, read-only reconciliation. Only the explicit payment action may call pay.
@MainActor final class LightningPaymentMonitor: ObservableObject {
    static let shared = LightningPaymentMonitor()
    @Published private(set) var pending: PendingNodePayment?
    @Published private(set) var status = ""
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var completedHash = ""
    @Published private(set) var missingOnNode = false
    private var storageLoaded = false
    private var submitting = false
    private var task: Task<Void, Never>?
    private var node: LightningNode?
    private var nodeConnection: LightningConnection?
    private let pendingAccount = "lightning-pending-v1"

    func load() {
        guard pending == nil else { return }
        do {
            if let data = try WalletKeychain.read(pendingAccount), !data.isEmpty {
                pending = try JSONDecoder().decode(PendingNodePayment.self, from: data)
                try pending?.validate()
                status = "Checking the saved payment with your node…"
            }
            storageLoaded = true
        } catch { storageLoaded = false; status = "Could not read the saved payment. Unlock the device and reopen Paperclip." }
    }
    func useNode(_ node: LightningNode, connection: LightningConnection) { self.node = node; nodeConnection = connection }
    private func savedConnection() throws -> LightningConnection {
        guard let data = try WalletKeychain.read("lightning-connection-v1") else {
            throw WalletFailure(message: "Configure the node used for this payment.")
        }
        return try JSONDecoder().decode(LightningConnection.self, from: data)
    }
    private func storedAttempt() throws -> PendingNodePayment? {
        guard let data = try WalletKeychain.read(pendingAccount), !data.isEmpty else { return nil }
        return try JSONDecoder().decode(PendingNodePayment.self, from: data)
    }
    private func stillCurrent(_ attempt: PendingNodePayment, connection: LightningConnection) throws -> Bool {
        guard pending == attempt, try storedAttempt() == attempt else { return false }
        return try savedConnection() == connection
    }
    func assignOriginalNode(_ reviewed: PendingNodePayment, connection: LightningConnection) throws {
        let stored = try storedAttempt()
        guard storageLoaded, !checking, !submitting, pending == reviewed,
              stored == reviewed, node != nil, nodeConnection == connection, try savedConnection() == connection else {
            throw WalletFailure(message: "The payment or connection changed. Reconnect and review the original node again.")
        }
        let assigned = try reviewed.assigningOriginalNode(connection)
        try WalletKeychain.save(JSONEncoder().encode(assigned), account: pendingAccount)
        pending = assigned; missingOnNode = false; lastChecked = nil
        status = "Original node saved. Check the payment without resending."
    }
    func record(_ attempt: PendingNodePayment) throws {
        guard storageLoaded, pending == nil, try storedAttempt() == nil else { throw WalletFailure(message: "A saved payment must be checked before sending.") }
        try attempt.validate()
        guard attempt.matches(try savedConnection()) else { throw WalletFailure(message: "The node connection changed. Review the payment again.") }
        try WalletKeychain.save(JSONEncoder().encode(attempt), account: pendingAccount)
        submitting = true
        missingOnNode = false
        pending = attempt; status = "Payment in progress. Checking automatically…"; lastChecked = nil
    }
    func submissionResult(_ data: Data, hash: String, implementation: LightningImplementation) throws {
        guard pending?.hash == hash else { return }
        if implementation == .lnd, let terminal = try LNDStreamResponse.terminalState(data, hash: hash) {
            try finish(hash: hash, terminal: terminal)
        }
    }
    func submissionRejected(_ error: Error, hash: String) throws -> Bool {
        guard let rejection = error as? LNDStreamError, rejection.definitelyRejected else { return false }
        try finish(hash: hash, terminal: "failed")
        status = "Not sent. " + rejection.localizedDescription
        return true
    }
    private func finish(hash: String, terminal: String) throws {
        guard let pending, pending.hash == hash else { return }
        // The hash alone does not identify a reviewed recovery record. Read
        // durable state again before deleting it, including submission replies.
        guard try storedAttempt() == pending else {
            throw WalletFailure(message: "The saved payment changed. Reopen Paperclip before checking its status again.")
        }
        try WalletKeychain.save(Data(), account: pendingAccount)
        self.pending = nil; missingOnNode = false; completedHash = hash
        status = terminal == "succeeded" ? "Payment successful." : "Payment failed. Your node confirmed it did not complete."
    }
    func clearMissingAttempt(hash: String) throws {
        guard !submitting, !checking, missingOnNode, pending?.hash == hash,
              try pending?.matches(savedConnection()) == true else {
            throw WalletFailure(message: "Check the payment on your node again before clearing this saved attempt.")
        }
        // Only an explicit user confirmation after an exact-hash NOT_FOUND lookup.
        // A timeout or empty history page never unlocks a payment automatically.
        try finish(hash: hash, terminal: "failed")
        status = "Saved attempt cleared after your confirmation. Review a new payment to continue."
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
        var checkedConnection: LightningConnection?
        do {
            try attempt.validate()
            guard try storedAttempt() == attempt else {
                throw WalletFailure(message: "The saved payment changed. Reopen Paperclip before checking its status again.")
            }
            if attempt.needsNodeReview {
                missingOnNode = false
                status = "This older payment has no saved node identity. Confirm its original node in Payment status before checking."
                return
            }
            let saved = try savedConnection()
            guard attempt.matches(saved) else { throw WalletFailure(message: "Reconnect the original node to check this payment.") }
            checkedConnection = saved
            if node == nil || nodeConnection != saved {
                var connection = saved
                if connection.useTor { connection.torProxy = try await EmbeddedTor.shared.proxy(for: connection.torProxy) }
                node = try LightningNode(connection: connection)
                nodeConnection = saved
            }
            guard let node else { return }
            let implementation = saved.implementation
            let terminal: String?
            if implementation == .lnd {
                let response = try await node.trackPayment(hash: attempt.hash)
                terminal = try LNDStreamResponse.terminalState(response, hash: attempt.hash)
            } else {
                let response = try await node.payments(hash: attempt.hash)
                terminal = try LightningPaymentState.terminalState(in: response, hash: attempt.hash, implementation: implementation)
            }
            try Task.checkCancellation()
            guard try stillCurrent(attempt, connection: saved) else {
                throw WalletFailure(message: "The saved payment or node connection changed. Reopen Paperclip before checking again.")
            }
            missingOnNode = false; lastChecked = Date()
            if let terminal { try finish(hash: attempt.hash, terminal: terminal) }
            else { status = "Payment is still in progress on your node. You can leave this page; Paperclip will check without resending." }
        } catch let error as LNDStreamError where error.code == 5 {
            guard let checkedConnection, (try? stillCurrent(attempt, connection: checkedConnection)) == true else { return }
            missingOnNode = true; lastChecked = Date()
            status = "Your node has no payment recorded for this exact hash. This can happen when an older app used an unsupported send method. Check your node before clearing the saved attempt."

        } catch is CancellationError {
            // Resume checking when the app becomes active again.
        } catch {
            missingOnNode = false
            node = nil; nodeConnection = nil
            status = "Unable to confirm yet. Paperclip will check again while open. \(error.localizedDescription)"
        }
    }
}
