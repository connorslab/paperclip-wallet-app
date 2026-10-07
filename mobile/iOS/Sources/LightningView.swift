import SwiftUI
import PaperclipMobile

private struct PendingNodePayment: Codable {
    let invoice: String
    let hash: String
}

struct LightningView: View {
    @EnvironmentObject var store: WalletStore
    @State private var connection = LightningConnection()
    @State private var client: LightningNode?
    @State private var nodeName = ""
    @State private var amount = ""
    @State private var receiveInvoice = ""
    @State private var payInvoice = ""
    @State private var maximumFee = "100"
    @State private var reviewedHash: String?
    @State private var reviewAmount = ""
    @State private var confirming = false
    @State private var pending: PendingNodePayment?
    @State private var status = ""
    @State private var showConnection = true
    private let configAccount = "lightning-connection-v1"
    private let pendingAccount = "lightning-pending-v1"
    var body: some View {
        Form {
            Section {
                Label("Your node. Your Lightning.", systemImage: "bolt.fill").font(.title2.bold())
                Text("Connect a BLAKE2b XBT Core Lightning or LND node. Node balances and channel backups remain on that node.").font(.caption)
            }
            Section("Node connection") {
                DisclosureGroup("\(nodeName.isEmpty ? "Configure node" : nodeName)", isExpanded: $showConnection) {
                    Picker("Implementation", selection: $connection.implementation) {
                        ForEach(LightningImplementation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("HTTPS or onion REST URL", text: $connection.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(connection.implementation == .cln ? "CLN rune" : "LND macaroon (hex)", text: $connection.credential)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("TLS certificate SHA256 (optional)", text: $connection.certificateSHA256)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Use Tor", isOn: $connection.useTor)
                    if connection.useTor {
                        TorProxyPicker(selection: $connection.torProxy)
                        Text("Enter your .onion REST address in the node URL field above.").font(.caption)
                    }
                    Button("Save and connect") { connect() }.disabled(pending != nil)
                    Text("Use a node-scoped rune or macaroon with only the permissions you need. Credentials stay in device-only Keychain.").font(.caption)
                }.disabled(pending != nil)
            }
            if client != nil {
                Section("Receive on your node") {
                    TextField("Amount in sats", text: $amount).keyboardType(.numberPad)
                    Button("Create Lightning invoice") { store.run {
                        guard let sats = UInt64(amount), let client else { throw WalletFailure(message: "Enter a positive amount.") }
                        receiveInvoice = try await client.invoice(amount: sats)
                    } }
                    if !receiveInvoice.isEmpty { ReceiveCode(value: receiveInvoice) }
                }
                Section("Pay from your node") {
                    TextField("BOLT11 invoice", text: $payInvoice, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Maximum routing fee in sats", text: $maximumFee).keyboardType(.numberPad)
                    Button("Review invoice") { review() }.disabled(pending != nil)
                    if reviewedHash != nil {
                        LabeledContent("Amount", value: reviewAmount)
                        LabeledContent("Maximum fee", value: "\(maximumFee) sats")
                        Button("Confirm Lightning payment") { confirming = true }.disabled(pending != nil)
                    }
                }
                Section("Payment status") {
                    if let pending { Text("An attempt is recorded for \(pending.hash). Check the node before another payment.").font(.caption.monospaced()) }
                    Button("Reconcile node payments") { reconcile() }
                    Text(status).font(.caption).textSelection(.enabled)
                }
            }
            Section { if store.busy { ProgressView() }; Text(store.message).font(.caption) }
        }.navigationTitle("Lightning").scrollContentBackground(.hidden).background(PaperclipTheme.navy).disabled(store.busy)
            .task { await load() }
            .onChange(of: payInvoice) { _, _ in reviewedHash = nil }
            .onChange(of: maximumFee) { _, _ in reviewedHash = nil }
            .onChange(of: connection) { old, _ in if !old.endpoint.isEmpty { client = nil; reviewedHash = nil } }
            .confirmationDialog("Pay this Lightning invoice?", isPresented: $confirming) {
                Button("Pay invoice") { pay() }
            } message: { Text("\(reviewAmount)\nMaximum fee: \(maximumFee) sats\n\(payInvoice)") }
    }
    private func load() async {
        do {
            if let data = try WalletKeychain.read(configAccount) { connection = try JSONDecoder().decode(LightningConnection.self, from: data) }
            if let data = try WalletKeychain.read(pendingAccount), !data.isEmpty { pending = try JSONDecoder().decode(PendingNodePayment.self, from: data) }
            if !connection.endpoint.isEmpty { client = try await makeNode() }
        } catch { store.message = error.localizedDescription }
    }
    private func makeNode() async throws -> LightningNode {
        var resolved = connection
        try resolved.validate()
        if resolved.useTor { resolved.torProxy = try await EmbeddedTor.shared.proxy(for: resolved.torProxy) }
        return try LightningNode(connection: resolved)
    }
    private func connect() {
        store.run {
            guard pending == nil else { throw WalletFailure(message: "Reconcile the saved node payment before changing nodes.") }
            let node = try await makeNode()
            let info = try JSONSerialization.jsonObject(with: await node.info()) as? [String: Any] ?? [:]
            // Both forks retain the upstream network names. The node must be configured for XBT.
            if connection.implementation == .cln {
                guard info["network"] as? String == (store.network == "xbt-mainnet" ? "bitcoin" : "regtest") else { throw WalletFailure(message: "Node network does not match the wallet.") }
            } else {
                let chains = info["chains"] as? [[String: String]] ?? []
                guard chains.contains(where: { $0["chain"] == "bitcoin" && $0["network"] == (store.network == "xbt-mainnet" ? "mainnet" : "regtest") }) else { throw WalletFailure(message: "Node network does not match the wallet.") }
            }
            try WalletKeychain.save(JSONEncoder().encode(connection), account: configAccount)
            client = node; nodeName = info["alias"] as? String ?? connection.implementation.title
            showConnection = false; store.message = "Lightning node connected."
        }
    }
    private func review() {
        store.run {
            reviewedHash = nil
            guard let client, UInt64(maximumFee) != nil, payInvoice.lowercased().hasPrefix(store.network == "xbt-mainnet" ? "lnbc" : "lnbcrt"),
                  !payInvoice.contains(where: \.isWhitespace) else { throw WalletFailure(message: "Enter a BOLT11 invoice for this network and a whole-sat fee limit.") }
            let review = try LightningPaymentReview.decode(await client.decode(payInvoice), implementation: connection.implementation)
            guard let fee = UInt64(maximumFee), fee <= UInt64.max / 1000 else { throw WalletFailure(message: "Fee limit is too large.") }
            let millis = review.millisatoshis
            reviewAmount = "\(millis / 1000) sats\(millis % 1000 == 0 ? "" : " + \(millis % 1000) msat")"
            reviewedHash = review.hash
        }
    }
    private func pay() {
        store.run {
            guard let client, let hash = reviewedHash, let fee = UInt64(maximumFee), pending == nil else { return }
            let attempt = PendingNodePayment(invoice: payInvoice, hash: hash)
            try WalletKeychain.save(JSONEncoder().encode(attempt), account: pendingAccount)
            pending = attempt; reviewedHash = nil
            do {
                let result = try JSONSerialization.jsonObject(with: await client.pay(attempt.invoice, maximumFee: fee)) as? [String: Any] ?? [:]
                status = result["status"] as? String ?? ((result["payment_error"] as? String ?? "").isEmpty ? "Submitted. Reconcile to confirm." : "Node reported a payment error. Reconcile before another attempt.")
            } catch { status = "Payment outcome is unknown. Reconcile the saved attempt before another payment." }
        }
    }
    private func reconcile() {
        store.run {
            guard let client else { return }
            let data = try await client.payments()
            guard let attempt = pending else { status = "Node payment history checked."; return }
            if let terminal = try LightningPaymentState.terminalState(in: data, hash: attempt.hash, implementation: connection.implementation) {
                try WalletKeychain.save(Data(), account: pendingAccount)
                pending = nil; status = "Saved payment: \(terminal)"
            } else {
                status = "The saved attempt is still pending or absent from history. Inspect the node before another attempt."
            }
        }
    }
}
