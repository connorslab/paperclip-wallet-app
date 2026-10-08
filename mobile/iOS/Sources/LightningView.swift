import SwiftUI
import PaperclipMobile

struct LightningView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    private enum Page: String, Hashable { case balance = "Node balance", connection = "Node connection", receive = "Receive on your node", pay = "Pay from your node", status = "Payment status" }
    @State private var page: Page?
    @State private var scanning = false
    @State private var connection = LightningConnection()
    @State private var client: LightningNode?
    @State private var nodeName = ""
    @State private var connectionError = ""
    @State private var amount = ""
    @State private var receiveInvoice = ""
    @State private var receiveOffer = false
    @State private var offerDescription = "Paperclip wallet"
    @State private var balance: LightningBalance?
    @State private var balanceStatus = ""
    @State private var payInvoice = ""
    @State private var maximumFee = ""
    @State private var payOffer = false
    @State private var offerAmount = ""
    @State private var resolvedInvoice: String?
    @State private var reviewedPayment: LightningPaymentReview?
    @State private var reviewDescription = ""
    @State private var reviewedHash: String?
    @State private var reviewAmount = ""
    @State private var confirming = false
    @ObservedObject private var payments = LightningPaymentMonitor.shared
    private var pending: PendingNodePayment? { payments.pending }
    @State private var status = ""
    private let configAccount = "lightning-connection-v1"
    var body: some View {
        ScrollView {
          VStack(spacing: 20) {
            WalletBrand()
            if client != nil {
                WalletSection {
                    HStack {
                        Label("Lightning balance", systemImage: "bolt.fill").foregroundStyle(PaperclipTheme.muted)
                        Spacer()
                        Button { store.run { await refreshBalance() } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh Lightning balance")
                    }
                    Text(balance.map { unit.display($0.sendableMsat / 1000) } ?? "—")
                        .font(.system(size: 36, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1).privacySensitive()
                    USDValue(sats: balance.map { $0.sendableMsat / 1000 }, mainnet: store.network == "xbt-mainnet")
                    Text(balance == nil ? "Balance unavailable · open details to retry" : "Available to send from your node").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    HStack {
                        Button { page = .pay } label: { Label("Pay", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }.modifier(GlassAction())
                        Button { page = .receive } label: { Label("Receive", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction())
                    }
                    Button { page = .balance } label: {
                        WalletNavigationRow("Balance details", subtitle: "Receive capacity and active channels", icon: "chart.bar")
                    }.buttonStyle(.plain)
                }
            } else {
                WalletSection {
                    Label("Your node. Your Lightning.", systemImage: "bolt.fill").font(.title2.bold())
                    Text("Connect your XBT Core Lightning or LND node to send and receive payments with Paperclip.")
                        .foregroundStyle(PaperclipTheme.muted)
                    Button("Connect a node") { page = .connection }.buttonStyle(WalletPrimaryButtonStyle())
                    if !connectionError.isEmpty { Text(connectionError).font(.caption).foregroundStyle(PaperclipTheme.muted) }
                }
            }
            WalletSection {
                Button { page = .connection } label: {
                    WalletNavigationRow(nodeName.isEmpty ? "Node connection" : nodeName,
                        subtitle: client == nil ? "Set up Core Lightning or LND" : connection.implementation.title + (connection.useTor ? " · Tor" : " · Direct connection"), icon: "server.rack")
                }.buttonStyle(.plain)
                Divider()
                Button { page = .status } label: {
                    WalletNavigationRow("Payments", subtitle: pending == nil ? "View your latest payment status" : "Payment in progress · checking automatically", icon: pending == nil ? "clock.arrow.circlepath" : "clock")
                }.buttonStyle(.plain)
            }
            Text("Funds and channel backups stay on your node. Paperclip is your connection to it.")
                .font(.caption).foregroundStyle(PaperclipTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            if store.busy { ProgressView("Connecting…") }
          }.padding(22).textFieldStyle(WalletInputStyle())
        }.navigationTitle("Lightning").background(WalletBackdrop()).disabled(store.busy)
            .navigationDestination(item: $page) { selected in
                ScrollView {
                    VStack(spacing: 20) {
                        switch selected {
                        case .balance: balanceCard
                        case .connection: connectionCard
                        case .receive: receiveCard
                        case .pay: payCard
                        case .status: statusCard
                        }
                        if store.busy || !store.message.isEmpty { WalletSection { if store.busy { ProgressView() }; Text(store.message).font(.caption) } }
                    }.padding(22).textFieldStyle(WalletInputStyle()).disabled(store.busy)
                }.background(WalletBackdrop()).navigationTitle(selected.rawValue).navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Pay this Lightning invoice?", isPresented: $confirming) {
                Button("Pay invoice") { pay() }
            } message: { Text("\(reviewAmount)\nMaximum fee: \(maximumFee) \(unit.title)\n\(payInvoice)") }
                    .fullScreenCover(isPresented: $scanning) {
                        QRScannerView { value in
                            let normalized = PaymentInput.normalized(value)
                            if normalized.lowercased().hasPrefix("lno1"), connection.implementation == .cln {
                                payOffer = true; payInvoice = normalized
                            } else if PaymentInput.isBolt11(normalized) || (normalized.lowercased().hasPrefix("lni1") && connection.implementation == .cln) {
                                payOffer = false; payInvoice = normalized
                            } else { status = "Scan a Lightning invoice or a BOLT12 offer. Offers require Core Lightning." }
                        }
                    }
            }
            .task { await load() }
            .onChange(of: payments.completedHash) { _, _ in
                status = payments.status; resolvedInvoice = nil; reviewedHash = nil
                Task { await refreshBalance() }
            }
            .onChange(of: unit) { old, new in
                amount = old.parse(amount).map { new.input($0) } ?? ""
                offerAmount = old.parse(offerAmount).map { new.input($0) } ?? ""
                maximumFee = old.parse(maximumFee).map { new.input($0) } ?? new.input(100)
                reviewedHash = nil; receiveInvoice = ""
            }
            .onChange(of: receiveOffer) { _, _ in receiveInvoice = "" }
            .onChange(of: amount) { _, _ in receiveInvoice = "" }
            .onChange(of: offerDescription) { _, _ in receiveInvoice = "" }
            .onChange(of: payInvoice) { _, value in
                reviewedHash = nil; resolvedInvoice = nil
                let request = PaymentInput.normalized(value).lowercased()
                if request.hasPrefix("lno1") { payOffer = true }
                else if request.hasPrefix("lni1") || PaymentInput.isBolt11(request) { payOffer = false }
            }
            .onChange(of: payOffer) { _, _ in reviewedHash = nil; resolvedInvoice = nil }
            .onChange(of: offerAmount) { _, _ in reviewedHash = nil; resolvedInvoice = nil }
            .onChange(of: maximumFee) { _, _ in reviewedHash = nil }
            .onChange(of: connection) { old, _ in if !old.endpoint.isEmpty { client = nil; reviewedHash = nil; balance = nil; receiveInvoice = ""; receiveOffer = false } }

    }
    private var balanceCard: some View {
        WalletSection("Channel balance") {
            LabeledContent("Available to send", value: balance.map { unit.display($0.sendableMsat / 1000) } ?? "—")
            USDValue(sats: balance.map { $0.sendableMsat / 1000 }, mainnet: store.network == "xbt-mainnet")
            LabeledContent("Receive capacity", value: balance.map { unit.display($0.receivableMsat / 1000) } ?? "—")
            if let balance { LabeledContent("Active channels", value: "\(balance.activeChannels)") }
            Text("These are estimates. Routes, channel liquidity, and fees can limit individual payments.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            Button("Refresh balance") { store.run { await refreshBalance() } }.buttonStyle(.bordered)
            if !balanceStatus.isEmpty { Text(balanceStatus).font(.caption).foregroundStyle(PaperclipTheme.muted) }
        }
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
                    Button("Save and connect") { connect() }.buttonStyle(WalletPrimaryButtonStyle()).disabled(pending != nil)
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
                    } }.buttonStyle(WalletPrimaryButtonStyle())
                    Text(receiveOffer ? "Reusable offer. Your node handles invoice requests and must stay online. Manage saved offers on your node." : "Payments go to your connected Lightning node.").font(.caption)
                    if connection.implementation == .lnd { Text("BOLT12 offer creation is available for Core Lightning nodes.").font(.caption) }
                    if !receiveInvoice.isEmpty { ReceiveCode(value: receiveInvoice) }
                }
    }
    private var payCard: some View {
        WalletSection("Pay from your node") {
                    if connection.implementation == .cln {
                        Picker("Payment type", selection: $payOffer) {
                            Text("Invoice").tag(false); Text("BOLT12 offer").tag(true)
                        }.pickerStyle(.segmented).disabled(pending != nil)
                    } else { Text("This LND connection supports BOLT11 payments. Use Core Lightning for BOLT12 offers.").font(.caption) }
                    Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }.disabled(pending != nil)
                    TextField(payOffer ? "BOLT12 offer (lno1…)" : "Lightning invoice", text: $payInvoice, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if payOffer {
                        Text("Review requests an invoice from the offer issuer. No payment is sent until you confirm.").font(.caption)
                        TextField(unit.amountPrompt + " (if needed)", text: $offerAmount)
                            .keyboardType(.decimalPad).accessibilityIdentifier("bolt12-payment-amount")
                        Text("Enter an amount for an amountless offer. Leave blank to use a fixed amount set by the offer.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    }
                    TextField("Maximum routing fee in \(unit.title)", text: $maximumFee).keyboardType(.decimalPad)
                    Button(payOffer ? "Request invoice & review" : "Review invoice") { review() }.buttonStyle(WalletPrimaryButtonStyle()).disabled(pending != nil)
                    if reviewedHash != nil {
                        if !reviewDescription.isEmpty { Text(reviewDescription).font(.subheadline).textSelection(.enabled) }
                        LabeledContent("Amount", value: reviewAmount)
                        LabeledContent("Maximum fee", value: "\(maximumFee) \(unit.title)")
                        Button("Confirm Lightning payment") { confirming = true }.buttonStyle(WalletPrimaryButtonStyle()).disabled(pending != nil)
                    }
                    if pending != nil { Text(payments.status).font(.caption).textSelection(.enabled) }
                    if !status.isEmpty && pending == nil { Text(status).font(.caption).textSelection(.enabled) }
                }
    }
    private var statusCard: some View {
        WalletSection("Payment status") {
                    if let pending { Text("Tracking payment \(pending.hash).").font(.caption.monospaced()) }
                    Text(payments.status.isEmpty ? "No pending payment. Paperclip checks new payments automatically while open." : payments.status).font(.subheadline)
                    if payments.checking { ProgressView("Checking with your node…") }
                    if let checked = payments.lastChecked { Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))").font(.caption) }
                    Button("Check now") { Task { await payments.checkNow() } }.disabled(payments.checking || pending == nil)
                }
    }
    private func load() async {
        if maximumFee.isEmpty { maximumFee = unit.input(100) }
        do {
            if let data = try WalletKeychain.read(configAccount) { connection = try JSONDecoder().decode(LightningConnection.self, from: data) }
            payments.load()
            if !connection.endpoint.isEmpty {
                let selected = connection
                let node = try await makeNode()
                guard selected == connection else { return }
                let info = try JSONSerialization.jsonObject(with: await node.info()) as? [String: Any] ?? [:]
                client = node; payments.useNode(node)
                nodeName = info["alias"] as? String ?? connection.implementation.title
                await refreshBalance()
            }
        } catch { connectionError = error.localizedDescription }
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
            client = node; payments.useNode(node); nodeName = info["alias"] as? String ?? connection.implementation.title
            page = nil; store.message = "Lightning node connected."
            await refreshBalance()
        }
    }
    private func review() {
        let request = PaymentInput.normalized(payInvoice), feeText = maximumFee, selectedUnit = unit, chosenAmount = offerAmount
        let isOffer = payOffer || request.lowercased().hasPrefix("lno1")
        store.run {
            reviewedHash = nil; resolvedInvoice = nil; reviewedPayment = nil; status = ""
            do {
                guard let client, let fee = selectedUnit.parse(feeText), fee <= UInt64.max / 1000,
                      !request.contains(where: \.isWhitespace) else { throw WalletFailure(message: "Enter a Lightning request and a valid fee limit.") }
                var invoice = request
                var expectedMsat: UInt64?
                if isOffer {
                    guard connection.implementation == .cln else { throw WalletFailure(message: "BOLT12 offers require Core Lightning.") }
                    let offer = try LightningOfferReview.decode(await client.decode(request))
                    let entered = chosenAmount.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sats = entered.isEmpty ? nil : selectedUnit.parse(entered)
                    guard entered.isEmpty || sats != nil else {
                        throw WalletFailure(message: "Enter a valid amount in \(selectedUnit.title). XBT supports up to 8 decimal places.")
                    }
                    expectedMsat = try offer.requestedAmount(enteredSats: sats)
                    invoice = try await client.fetchOfferInvoice(request, amountMsat: expectedMsat)
                } else {
                    guard request.lowercased().hasPrefix(store.network == "xbt-mainnet" ? "lnbc" : "lnbcrt") ||
                          (connection.implementation == .cln && request.lowercased().hasPrefix("lni1")) else {
                        throw WalletFailure(message: "Enter an invoice for this network, or choose BOLT12 offer.")
                    }
                }
                let decoded = try await client.decode(invoice)
                let review = try LightningPaymentReview.decode(decoded, implementation: connection.implementation)
                if let expectedMsat, expectedMsat != review.millisatoshis {
                    throw WalletFailure(message: "The fetched invoice amount differs from the offer or requested amount. No payment was sent.")
                }
                guard request == PaymentInput.normalized(payInvoice), feeText == maximumFee, selectedUnit == unit, chosenAmount == offerAmount else { return }
                let fields = try JSONSerialization.jsonObject(with: decoded) as? [String: Any] ?? [:]
                reviewDescription = fields["offer_description"] as? String ?? fields["description"] as? String ?? ""
                let millis = review.millisatoshis
                reviewAmount = "\(unit.display(millis / 1000))\(millis % 1000 == 0 ? "" : " + \(millis % 1000) msat")"
                resolvedInvoice = invoice; reviewedPayment = review; reviewedHash = review.hash
            } catch { status = error.localizedDescription }
        }
    }
    private func pay() {
        store.run {
            guard let client, let hash = reviewedHash, let invoice = resolvedInvoice, let reviewedPayment,
                  let fee = unit.parse(maximumFee), pending == nil else { return }
            // Revalidate expiry and bind the saved attempt to the exact reviewed invoice.
            let current = try LightningPaymentReview.decode(await client.decode(invoice), implementation: connection.implementation)
            guard current == reviewedPayment else { throw WalletFailure(message: "Invoice changed or expired. Review again.") }
            let attempt = PendingNodePayment(invoice: invoice, hash: hash)
            try payments.record(attempt)
            reviewedHash = nil
            do {
                let result = try JSONSerialization.jsonObject(with: await client.pay(attempt.invoice, maximumFee: fee)) as? [String: Any] ?? [:]
                status = result["status"] as? String ?? ((result["payment_error"] as? String ?? "").isEmpty ? "Submitted. Checking automatically." : "Node reported an error. Checking the final outcome automatically.")
            } catch { status = "Payment outcome is not confirmed yet. Paperclip will check automatically without resending." }
            payments.submissionFinished()
            await payments.checkNow()
            if pending == nil { status = payments.status }
        }
    }
}
