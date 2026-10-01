import SwiftUI

struct WalletWorkbench: View {
    @State private var busy = false
    @State private var message = "Create an isolated wallet to test native storage. No mainnet funds can be used."
    @State private var fingerprint = ""
    @State private var address = ""
    @State private var server = ""
    @State private var rpc = ""
    @State private var username = ""
    @State private var password = ""
    @State private var destination = ""
    @State private var amount = ""
    @State private var quotedTotal: UInt64?
    @State private var quoteText = ""
    @State private var confirming = false
    private let wallet = NativeWallet.shared

    var body: some View {
        Form {
            Section("Native wallet · Regtest only") {
                Text("Keys stay in this device’s Keychain. Storage is accessible after the first unlock so background refresh can work. Keep an encrypted full-wallet backup.").font(.caption)
                Button("Create test wallet") { perform { fingerprint = try await wallet.open(create: true); message = "Test wallet saved securely." } }
                    .accessibilityIdentifier("create-test-wallet")
                Button("Reopen saved wallet") { perform { fingerprint = try await wallet.open(); message = "Saved wallet reopened." } }
                if !fingerprint.isEmpty { Text("Wallet: \(fingerprint)").accessibilityIdentifier("wallet-fingerprint") }
                NavigationLink("Encrypted backup & restore") { BackupView(engine: wallet) }
            }
            Section("Test backend") {
                TextField("Ark server URL", text: $server).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Indexed regtest Bitcoin RPC URL", text: $rpc).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("RPC username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("RPC password", text: $password)
                Text("Use an isolated regtest backend. Connection credentials are stored in this device’s Keychain for future refreshes.").font(.caption)
                Button("Connect and synchronize") { perform {
                    try await wallet.connect(server: server, rpc: rpc, username: username, password: password)
                    password = ""
                    try await sync()
                } }
                Button("Synchronize balances") { perform { try await sync() } }
            }
            Section("Receive") {
                Button("New on-chain address") { perform { address = try await wallet.address(ark: false) } }
                    .accessibilityIdentifier("new-onchain-address")
                Button("New Ark address") { perform { address = try await wallet.address(ark: true) } }
                if !address.isEmpty { Text(address).font(.caption.monospaced()).textSelection(.enabled).accessibilityIdentifier("receive-address") }
            }
            Section("Pay from Ark") {
                TextField("Ark address, Lightning invoice or offer", text: $destination, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Amount in sats", text: $amount).keyboardType(.numberPad)
                Button("Review payment") { perform {
                    quotedTotal = nil
                    guard let sats = UInt64(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive whole-sat amount.") }
                    let quote = try await wallet.quote(destination: destination, amount: sats)
                    quotedTotal = (quote["total_sat"] as? NSNumber)?.uint64Value
                    quoteText = "Recipient: \(sats) sats\nTotal including fees and reserves: \(quotedTotal ?? 0) sats"
                } }
                if quotedTotal != nil {
                    Text(quoteText)
                    Button("Confirm payment") { confirming = true }.tint(.orange)
                }
            }
            Section { if busy { ProgressView() }; Text(message).accessibilityIdentifier("wallet-operation-status") }
        }
        .navigationTitle("Wallet lab")
        .disabled(busy)
        .onChange(of: destination) { _, _ in quotedTotal = nil }
        .onChange(of: amount) { _, _ in quotedTotal = nil }
        .confirmationDialog("Send this regtest payment?", isPresented: $confirming) {
            Button("Send payment") { perform {
                guard let total = quotedTotal, let sats = UInt64(amount) else { return }
                quotedTotal = nil
                do {
                    let result = try await wallet.send(destination: destination, amount: sats, total: total)
                    message = "Payment status: \(result["state"] as? String ?? "unknown"). Synchronize before another payment."
                } catch {
                    message = "Payment was not confirmed: \(error.localizedDescription). Check activity before trying again."
                }
            } }
        } message: { Text("\(destination)\n\(quoteText)") }
    }
    private func sync() async throws {
        let state = try await wallet.balances()
        message = "Ark: \(state["ark_sat"] ?? 0) sats · On-chain: \(state["onchain_sat"] ?? 0) sats · Pending: \(state["pending_sat"] ?? 0) sats"
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() } catch { message = error.localizedDescription }
        }
    }
}
