import SwiftUI
import PaperclipMobile

private struct PendingNodePayment: Codable {
    let invoice: String
    let hash: String
}

struct LightningView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    private enum Page: String, Hashable { case connection = "Node connection", receive = "Receive on your node", pay = "Pay from your node", status = "Payment status" }
    @State private var page: Page?
    @State private var scanning = false
    @State private var connection = LightningConnection()
    @State private var client: LightningNode?
    @State private var nodeName = ""
    @State private var amount = ""
    @State private var receiveInvoice = ""
    @State private var receiveOffer = false
    @State private var offerDescription = "Paperclip wallet"
    @State private var balance: LightningBalance?
    @State private var balanceStatus = ""
    @State private var payInvoice = ""
    @State private var maximumFee = ""
    @State private var reviewedHash: String?
    @State private var reviewAmount = ""
    @State private var confirming = false
    @State private var pending: PendingNodePayment?
    @State private var status = ""
    private let configAccount = "lightning-connection-v1"
    private let pendingAccount = "lightning-pending-v1"
    var body: some View {
        ScrollView {
          VStack(spacing: 20) {
            WalletSection {
                Label("Your node. Your Lightning.", systemImage: "bolt.fill").font(.title2.bold())
                Text("Connect a BLAKE2b XBT Core Lightning or LND node. Node balances and channel backups remain on that node.").font(.caption)
            }

            if client != nil {
                WalletSection("Lightning balance") {
                    Text(balance.map { unit.display($0.sendableMsat / 1000) } ?? "—")
                        .font(.system(size: 36, weight: .semibold, design: .rounded)).privacySensitive()
                    Text("Estimated available to send").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    LabeledContent("Receive capacity", value: balance.map { unit.display($0.receivableMsat / 1000) } ?? "—")
                    if let balance { Text("\(balance.activeChannels) active channels · routing and fees can limit payments").font(.caption) }
                    Button("Refresh balance") { store.run { await refreshBalance() } }.modifier(GlassAction())
                    if !balanceStatus.isEmpty { Text(balanceStatus).font(.caption) }
                }
            }
            WalletSection("Your node") {
                LabeledContent("Node", value: client == nil ? "Not connected" : (nodeName.isEmpty ? connection.implementation.title : nodeName))
                Button("Connection settings") { page = .connection }
                if client != nil {
                    HStack {
                        Button { page = .pay } label: { Label("Pay", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }.modifier(GlassAction())
                        Button { page = .receive } label: { Label("Receive", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction())
                    }
                }
                Button("Payment status & reconciliation") { page = .status }
                if pending != nil { Label("A payment needs checking", systemImage: "clock").font(.caption) }
            }
            WalletSection { if store.busy { ProgressView() }; Text(store.message).font(.caption) }
          }.padding(22).textFieldStyle(WalletInputStyle())
        }.navigationTitle("Lightning").background(PaperclipTheme.navy.ignoresSafeArea()).disabled(store.busy)
            .navigationDestination(item: $page) { selected in
                ScrollView {
                    VStack(spacing: 20) {
                        switch selected {
                        case .connection: connectionCard
                        case .receive: receiveCard
                        case .pay: payCard
                        case .status: statusCard
                        }
                        if store.busy || !store.message.isEmpty { WalletSection { if store.busy { ProgressView() }; Text(store.message).font(.caption) } }
                    }.padding(22).textFieldStyle(WalletInputStyle()).disabled(store.busy)
                }.background(PaperclipTheme.navy.ignoresSafeArea()).navigationTitle(selected.rawValue).navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Pay this Lightning invoice?", isPresented: $confirming) {
                Button("Pay invoice") { pay() }
            } message: { Text("\(reviewAmount)\nMaximum fee: \(maximumFee) \(unit.title)\n\(payInvoice)") }
                    .sheet(isPresented: $scanning) {
                        QRScannerView { value in
                            let normalized = PaymentInput.normalized(value)
                            if PaymentInput.isBolt11(normalized) { payInvoice = normalized }
                            else { status = "Scan a BOLT11 invoice to pay from your Lightning node." }
                        }
                    }
            }
            .task { await load() }
            .onChange(of: unit) { old, new in
                amount = old.parse(amount).map { new.input($0) } ?? ""
                maximumFee = old.parse(maximumFee).map { new.input($0) } ?? new.input(100)
                reviewedHash = nil; receiveInvoice = ""
            }
            .onChange(of: receiveOffer) { _, _ in receiveInvoice = "" }
            .onChange(of: amount) { _, _ in receiveInvoice = "" }
            .onChange(of: offerDescription) { _, _ in receiveInvoice = "" }
            .onChange(of: payInvoice) { _, _ in reviewedHash = nil }
            .onChange(of: maximumFee) { _, _ in reviewedHash = nil }
            .onChange(of: connection) { old, _ in if !old.endpoint.isEmpty { client = nil; reviewedHash = nil; balance = nil; receiveInvoice = ""; receiveOffer = false } }

    }
    private var connectionCard: some View {
        WalletSection("Node connection") {
                Group {
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
    }
    private var receiveCard: some View {
        WalletSection("Receive on your node") {
                    Picker("Payment request", selection: $receiveOffer) {
                        Text("BOLT11 invoice").tag(false)
                        if connection.implementation == .cln { Text("BOLT12 offer").tag(true) }
                    }.pickerStyle(.segmented)
                    TextField(receiveOffer ? unit.amountPrompt + " (optional)" : unit.amountPrompt, text: $amount).keyboardType(.decimalPad)
                    if receiveOffer { TextField("Offer description", text: $offerDescription) }
                    Button(receiveOffer ? "Create BOLT12 offer" : "Create Lightning invoice") { store.run {
                        guard let client else { return }
                        receiveInvoice = ""
                        if receiveOffer {
                            let sats = amount.isEmpty ? nil : unit.parse(amount)
                            guard amount.isEmpty || (sats != nil && sats! > 0) else { throw WalletFailure(message: "Enter a positive amount, or leave it blank.") }
                            receiveInvoice = try await client.offer(amount: sats, description: offerDescription)
                        } else {
                            guard let sats = unit.parse(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive amount.") }
                            receiveInvoice = try await client.invoice(amount: sats)
                        }
                    } }.modifier(GlassAction())
                    Text(receiveOffer ? "Reusable offer. Your node handles invoice requests and must stay online. Manage saved offers on your node." : "Payments go to your connected Lightning node.").font(.caption)
                    if connection.implementation == .lnd { Text("BOLT12 offer creation is available for Core Lightning nodes.").font(.caption) }
                    if !receiveInvoice.isEmpty { ReceiveCode(value: receiveInvoice) }
                }
    }
    private var payCard: some View {
        WalletSection("Pay from your node") {
                    Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }.disabled(pending != nil)
                    TextField("BOLT11 invoice", text: $payInvoice, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Maximum routing fee in \(unit.title)", text: $maximumFee).keyboardType(.decimalPad)
                    Button("Review invoice") { review() }.disabled(pending != nil)
                    if reviewedHash != nil {
                        LabeledContent("Amount", value: reviewAmount)
                        LabeledContent("Maximum fee", value: "\(maximumFee) \(unit.title)")
                        Button("Confirm Lightning payment") { confirming = true }.disabled(pending != nil)
                    }
                    if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
                }
    }
    private var statusCard: some View {
        WalletSection("Payment status") {
                    if let pending { Text("An attempt is recorded for \(pending.hash). Check the node before another payment.").font(.caption.monospaced()) }
                    Button("Reconcile node payments") { reconcile() }
                    Text(status).font(.caption).textSelection(.enabled)
                }
    }
    private func load() async {
        if maximumFee.isEmpty { maximumFee = unit.input(100) }
        do {
            if let data = try WalletKeychain.read(configAccount) { connection = try JSONDecoder().decode(LightningConnection.self, from: data) }
            if let data = try WalletKeychain.read(pendingAccount), !data.isEmpty { pending = try JSONDecoder().decode(PendingNodePayment.self, from: data) }
            if !connection.endpoint.isEmpty {
                let selected = connection
                let node = try await makeNode()
                guard selected == connection else { return }
                let info = try JSONSerialization.jsonObject(with: await node.info()) as? [String: Any] ?? [:]
                client = node
                nodeName = info["alias"] as? String ?? connection.implementation.title
                await refreshBalance()
            }
        } catch { store.message = error.localizedDescription }
    }
    private func refreshBalance() async {
        guard let client else { return }
        do { balance = try await client.balance(); balanceStatus = "Updated \(Date().formatted(date: .omitted, time: .shortened))" }
        catch { balance = nil; balanceStatus = error.localizedDescription }
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
            page = nil; store.message = "Lightning node connected."
            await refreshBalance()
        }
    }
    private func review() {
        store.run {
            reviewedHash = nil
            guard let client, unit.parse(maximumFee) != nil, payInvoice.lowercased().hasPrefix(store.network == "xbt-mainnet" ? "lnbc" : "lnbcrt"),
                  !payInvoice.contains(where: \.isWhitespace) else { throw WalletFailure(message: "Enter a BOLT11 invoice for this network and a whole-sat fee limit.") }
            let review = try LightningPaymentReview.decode(await client.decode(payInvoice), implementation: connection.implementation)
            guard let fee = unit.parse(maximumFee), fee <= UInt64.max / 1000 else { throw WalletFailure(message: "Fee limit is too large.") }
            let millis = review.millisatoshis
            reviewAmount = "\(unit.display(millis / 1000))\(millis % 1000 == 0 ? "" : " + \(millis % 1000) msat")"
            reviewedHash = review.hash
        }
    }
    private func pay() {
        store.run {
            guard let client, let hash = reviewedHash, let fee = unit.parse(maximumFee), pending == nil else { return }
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
