import SwiftUI
import PaperclipMobile

struct LightningBridgeView: View {
    @EnvironmentObject private var store: WalletStore
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @ObservedObject private var model = LightningBridgeModel.shared
    @ObservedObject private var payments = LightningPaymentMonitor.shared
    @State private var source: BridgePaymentRecord.Source
    @State private var invoice = ""
    @State private var estimate: BridgeEstimate?
    @State private var parsed: BridgeInvoice?
    @State private var busy = false
    @State private var scanning = false
    @State private var confirming = false
    @State private var newPayment = false
    @State private var fee = ""
    @State private var reviewedTotal: UInt64?
    @State private var fundingReview: LightningPaymentReview?
    @State private var node: LightningNode?
    @State private var nodeConnection: LightningConnection?
    @State private var reviewedAt: Date?
    @State private var reviewedQuote: BridgeQuote?
    @State private var message = ""
    @State private var settings = false
    @State private var apiKey = ""
    init(source: BridgePaymentRecord.Source = .node) { _source = State(initialValue: source) }
    private var current: BridgePaymentRecord? { newPayment ? nil : model.current }
    private var arkAvailable: Bool { store.hasWallet && store.supportsArk && store.network == "xbt-mainnet" && !store.isWatchOnly && !store.isHardware }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletSection {
                    HStack { Label("Paperclip Bridge", systemImage: "arrow.left.arrow.right").font(.headline).foregroundStyle(PaperclipTheme.orange); Spacer(); BridgeStatusBadge(direction: .paySpamcoin) }
                    Text("Pay a Spamcoin (BTC) invoice using XBT from Ark or your node.")
                        .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    Label("Beta · Mainnet", systemImage: "flask").font(.caption)
                }
                if let record = current { paymentCard(record) }
                else { composeCard }
                if busy { ProgressView("Checking payment…") }
                if !message.isEmpty { WalletSection { Text(message).font(.subheadline).textSelection(.enabled) } }
                if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(PaperclipTheme.muted) }
                WalletSection {
                    NavigationLink { historyPage } label: {
                        WalletNavigationRow("Bridge activity", subtitle: "Saved quotes and payment outcomes", icon: "clock.arrow.circlepath")
                    }.buttonStyle(.plain)
                    Divider()
                    Button { settings = true } label: {
                        WalletNavigationRow("Bridge connection", subtitle: model.hasPrivateKey ? "Private wallet API" : "Public API · no key required", icon: "network")
                    }.buttonStyle(.plain)
                    Text("USD values are estimates from xbt.live. Spamcoin (BTC) estimates also use the bridge’s quoted exchange rate.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    Text("The bridge receives the recipient’s invoice and network connection details. Your seed and node credentials stay on this device. XBT and Spamcoin (BTC) are separate networks.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
            }.walletPageContent().textFieldStyle(WalletInputStyle())
        }.walletPageBackground().navigationTitle("Pay Spamcoin (BTC)").navigationBarTitleDisplayMode(.inline)
            .task {
                model.load(); payments.load()
                if fee.isEmpty { fee = unit.input(100) }
                await model.refreshAvailability(); await model.refreshStatus()
            }
            .fullScreenCover(isPresented: $scanning) {
                QRScannerView { value in invoice = PaymentInput.normalized(value); clearReview() }
            }
            .sheet(isPresented: $settings) { connectionPage }
            .confirmationDialog("Pay this Spamcoin (BTC) invoice?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Pay with XBT") { pay() }
            } message: {
                if let record = current {
                    Text("Recipient: \(btcAmount(record.quote.sat))\nMaximum XBT debit: \(unit.display(reviewedTotal))\nSource: \(record.source.title)")
                }
            }
            .onChange(of: invoice) { _, _ in clearReview() }
            .onChange(of: source) { _, _ in clearReview() }
            .onChange(of: fee) { _, _ in reviewedTotal = nil; fundingReview = nil }
            .onChange(of: store.walletID) { _, _ in reviewedTotal = nil; fundingReview = nil }
            .onChange(of: unit) { old, new in fee = old.parse(fee).map { new.input($0) } ?? new.input(100); reviewedTotal = nil }
    }
    private var composeCard: some View {
        WalletSection("Payment request") {
            Picker("Pay with", selection: $source) {
                ForEach(BridgePaymentRecord.Source.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(busy)
            if source == .ark {
                LabeledContent("Available", value: unit.display(store.ark))
                USDValue(sats: store.ark)
                Text(arkAvailable ? store.selectedProfile?.name ?? "Selected Ark wallet" : "Select a mainnet mobile wallet with Ark to use this source.")
                    .font(.caption).foregroundStyle(PaperclipTheme.muted)
            } else { Text("Uses the shared XBT Core Lightning or LND connection from the Lightning tab.").font(.caption).foregroundStyle(PaperclipTheme.muted) }
            Button { scanning = true } label: { Label("Scan invoice", systemImage: "qrcode.viewfinder") }.disabled(busy)
            TextField("Spamcoin (BTC) Lightning invoice", text: $invoice, axis: .vertical)
                .lineLimit(3...5).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                .accessibilityIdentifier("bridge-recipient")
            if let availability = model.availability {
                if let min = availability.min_sat, let max = availability.max_sat {
                    Text("Current range: \(btcAmount(min)) – \(btcAmount(max))").font(.caption)
                }
            }
            if let estimate {
                Divider()
                LabeledContent("Recipient receives", value: btcAmount(estimate.sat))
                USDValue(sats: nil, equivalentSats: BridgeDirection.paySpamcoin.xbtEquivalentSats(spamcoinSats: estimate.sat, rate: estimate.rate))
                LabeledContent("Estimated XBT", value: unit.display(estimate.estimate_sat))
                USDValue(sats: estimate.estimate_sat)
                Text("The final conversion and bridge fee are fixed in the next quote. Your funding wallet may charge an additional fee.")
                    .font(.caption).foregroundStyle(PaperclipTheme.muted)
                Button("Get XBT quote") { getQuote() }.buttonStyle(WalletPrimaryButtonStyle()).disabled(busy)
            } else {
                Button("Review invoice") { checkInvoice() }.buttonStyle(WalletPrimaryButtonStyle())
                    .disabled(busy || invoice.isEmpty || (source == .ark && !arkAvailable))
            }
        }
    }
    @ViewBuilder private func paymentCard(_ record: BridgePaymentRecord) -> some View {
        WalletSection(record.submitted ? "Payment status" : "Review bridge quote") {
            HStack {
                Label(record.source.title, systemImage: record.source == .ark ? "square.stack.3d.up" : "bolt.fill")
                Spacer()
                if model.checking { ProgressView() }
            }.font(.subheadline)
            LabeledContent("Recipient receives", value: btcAmount(record.quote.sat))
            USDValue(sats: nil, equivalentSats: BridgeDirection.paySpamcoin.xbtEquivalentSats(spamcoinSats: record.quote.sat, rate: record.quote.rate))
            LabeledContent("Bridge invoice", value: unit.display(record.quote.pay_sat)).font(.headline)
            USDValue(sats: record.quote.pay_sat)
            LabeledContent("Bridge fee included", value: String(format: "%.2f%%", record.quote.spread * 100))
            LabeledContent("Exchange rate", value: String(format: "%.8f BTC / XBT", record.quote.rate))
            Text(record.walletName).font(.caption).foregroundStyle(PaperclipTheme.muted)
            if record.submitted {
                Divider()
                Label(record.verifiedSettlement ? "Spamcoin (BTC) invoice paid" : statusTitle(record), systemImage: record.verifiedSettlement ? "checkmark.circle.fill" : "clock")
                Text(record.verifiedSettlement ? "Payment proof verified. Your recipient’s invoice is paid." : "Keep Paperclip open for updates. A timeout does not mean failure; this payment will not be sent again.")
                    .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                Text("XBT funding: \(record.fundingState.replacingOccurrences(of: "_", with: " "))").font(.caption)
                Button("Check status") { run { await checkFunding(record); await model.refreshStatus() } }.disabled(busy)
                if record.canStartAnother { Button("New payment") { newPayment = true; invoice = ""; clearReview() }.buttonStyle(WalletPrimaryButtonStyle()) }
                if record.source == .ark && record.walletID != store.walletID {
                    Text("Switch to \(record.walletName) in Settings to check its Ark funding status.").font(.caption)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(Double(record.quote.expires_at) - context.date.timeIntervalSince1970))
                    Label(seconds == 0 ? "Quote expired" : "Quote expires in \(seconds)s", systemImage: "timer").font(.caption).monospacedDigit()
                }
                if record.source == .node { TextField("Maximum routing fee in \(unit.title)", text: $fee).keyboardType(.decimalPad).disabled(busy) }
                if let total = reviewedTotal, reviewedQuote == record.quote {
                    Divider()
                    LabeledContent(record.source == .ark ? "Ark fee / recovery funding" : "Maximum routing fee", value: unit.display(total - record.quote.pay_sat))
                    LabeledContent("Maximum XBT debit", value: unit.display(total)).font(.headline)
                    USDValue(sats: total)
                    Button("Confirm payment") { confirming = true }.buttonStyle(WalletPrimaryButtonStyle()).disabled(busy)
                } else {
                    Button("Review \(record.source == .ark ? "Ark" : "node") payment") { reviewFunding(record) }
                        .buttonStyle(WalletPrimaryButtonStyle()).disabled(busy)
                }
                Button("Use another invoice") { newPayment = true; invoice = ""; clearReview() }.disabled(busy)
                Text("Your XBT payment can stay pending while the bridge routes the recipient’s invoice. Review all fees before confirming.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
        }
    }
    private var historyPage: some View {
        ScrollView {
            VStack(spacing: 20) {
                if model.records.isEmpty { WalletSection { Text("Bridge payments will appear here.") } }
                ForEach(model.records.reversed()) { record in
                    WalletSection {
                        LabeledContent(btcAmount(record.quote.sat), value: unit.display(record.quote.pay_sat))
                        Text(statusTitle(record)).font(.headline)
                        Text(record.created.formatted()).font(.caption).foregroundStyle(PaperclipTheme.muted)
                        Text("Payment hash").font(.caption)
                        Text(record.id).font(.caption.monospaced()).textSelection(.enabled)
                        if let proof = record.preimage { Text("Verified payment proof").font(.caption); Text(proof).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
            }.walletPageContent()
        }.walletPageBackground().navigationTitle("Bridge activity").toolbar { ToolbarItem(placement: .topBarTrailing) { BridgeStatusBadge(direction: .paySpamcoin) } }
    }
    private var connectionPage: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    WalletSection("Paperclip Bridge") {
                        BridgeStatusBadge(direction: .paySpamcoin)
                        Text("lightning.paperclip-xbt.xyz").font(.headline)
                        Text("The public API works without a key. For operator testing, enter your private wallet API key. It stays in device-only Keychain.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                        SecureField("Private API key (optional)", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Save connection") { do { try model.saveKey(apiKey); settings = false; reviewedTotal = nil; newPayment = true; clearReview() } catch { message = error.localizedDescription; settings = false } }
                            .buttonStyle(WalletPrimaryButtonStyle())
                    }
                }.walletPageContent().textFieldStyle(WalletInputStyle())
            }.walletPageBackground().navigationTitle("Bridge connection")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { settings = false } } }
                .task { apiKey = (try? WalletKeychain.read(LightningBridgeModel.keyAccount)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        }
    }
    private func btcAmount(_ sats: Double) -> String { sats.formatted(.number.precision(.fractionLength(0...3))) + " BTC sats" }
    private func statusTitle(_ r: BridgePaymentRecord) -> String {
        if r.verifiedSettlement { return "Spamcoin (BTC) invoice paid" }
        if !r.submitted { return Double(r.quote.expires_at) < Date().timeIntervalSince1970 ? "Unpaid quote expired" : "Quote ready · not paid" }
        switch r.bridgeState {
        case "funded", "paid", "paying": return "Paying Spamcoin (BTC) invoice"
        case "failed", "aborted", "expired": return "Bridge ended · checking XBT funds"
        case "lost": return "Payment needs attention · contact support"
        case "settled": return "Settlement reported · checking proof"
        default: return "Waiting for payment confirmation"
        }
    }
    private func clearReview() { estimate = nil; parsed = nil; reviewedTotal = nil; fundingReview = nil; message = "" }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = ""
        Task { @MainActor in defer { busy = false }; do { try await action() } catch { message = error.localizedDescription } }
    }
    private func checkInvoice() {
        let text = invoice, chosen = source
        run {
            let target = try BridgeInvoice(text); try target.validateTarget()
            let api = try model.client(), availability = try await api.availability()
            model.availability = availability
            guard availability.open else { throw BridgeError.unavailable("The bridge is temporarily unavailable. Try again shortly.") }
            let result = try await api.check(target.text); try result.validate(target: target)
            guard text == invoice, chosen == source else { return }
            parsed = target; estimate = result
        }
    }
    private func getQuote() {
        guard let target = parsed else { return }
        let chosen = source, walletID = store.walletID
        run {
            try target.validateTarget()
            if chosen == .ark && !arkAvailable { throw WalletFailure(message: "Select an Ark-enabled mainnet wallet.") }
            let result = try await model.client().quote(target)
            guard parsed == target, source == chosen, chosen != .ark || walletID == store.walletID else { throw BridgeError.invalidQuote }
            try model.record(target: target, quote: result, source: chosen, store: store)
            newPayment = false; reviewedTotal = nil
        }
    }
    private func connectedNode() async throws -> (LightningNode, LightningConnection) {
        guard let data = try WalletKeychain.read("lightning-connection-v1") else { throw WalletFailure(message: "Connect your XBT Core Lightning or LND node in the Lightning tab first.") }
        let saved = try JSONDecoder().decode(LightningConnection.self, from: data)
        var resolved = saved
        if resolved.useTor { resolved.torProxy = try await EmbeddedTor.shared.proxy(for: resolved.torProxy) }
        let node = try LightningNode(connection: resolved)
        let info = try JSONSerialization.jsonObject(with: await node.info()) as? [String: Any] ?? [:]
        guard try LightningNetwork.decode(info, implementation: saved.implementation) == .mainnet else { throw WalletFailure(message: "The bridge requires an XBT mainnet node.") }
        return (node, saved)
    }
    private func reviewFunding(_ record: BridgePaymentRecord) {
        run {
            reviewedTotal = nil
            let hold = try record.quote.validate(target: BridgeInvoice(record.target))
            guard !record.submitted else { return }
            if record.source == .ark {
                guard arkAvailable, record.walletID == store.walletID, !store.busy, hold.msat % 1000 == 0 else {
                    throw WalletFailure(message: "Open the original Ark wallet. Ark funding requires a whole-sat XBT invoice.")
                }
                let quote = try await store.engine.quote(destination: record.quote.hold_invoice, amount: record.quote.pay_sat)
                guard record.walletID == store.walletID, let total = (quote["total_sat"] as? NSNumber)?.uint64Value, total >= record.quote.pay_sat else { throw BridgeError.invalidQuote }
                if let balance = store.ark, total > balance { throw WalletFailure(message: "Your Ark balance does not cover the invoice and fees.") }
                reviewedTotal = total
            } else {
                guard payments.pending == nil, let maxFee = unit.parse(fee), maxFee <= 2_100_000_000_000_000 - record.quote.pay_sat else { throw WalletFailure(message: "Enter a valid routing fee limit and finish any pending node payment first.") }
                let (client, saved) = try await connectedNode()
                let review = try LightningPaymentReview.decode(await client.decode(record.quote.hold_invoice), implementation: saved.implementation)
                guard review.hash == hold.hash, review.millisatoshis == hold.msat else { throw BridgeError.invalidQuote }
                node = client; nodeConnection = saved; fundingReview = review
                reviewedTotal = record.quote.pay_sat + maxFee
            }
            reviewedQuote = record.quote
            reviewedAt = Date()
        }
    }
    private func pay() {
        guard let record = current, let total = reviewedTotal, reviewedQuote == record.quote, !record.submitted else { return }
        run {
            _ = try record.quote.validate(target: BridgeInvoice(record.target))
            guard let reviewedAt, Date().timeIntervalSince(reviewedAt) < 50 else { reviewedTotal = nil; throw BridgeError.expired }
            if record.source == .ark {
                guard arkAvailable, store.walletID == record.walletID, !store.busy else { throw WalletFailure(message: "Open the reviewed Ark wallet and wait for other operations to finish.") }
                // Pin the selected wallet across suspension points and the native send.
                let held = try await store.engine.holdMaintenanceWallet()
                guard held?.id == record.walletID else { await store.engine.releaseMaintenanceWallet(); throw BridgeError.invalidQuote }
                store.busy = true
                do {
                    try model.beginSubmission(record)
                    reviewedTotal = nil
                    let result = try await store.engine.send(destination: record.quote.hold_invoice, amount: record.quote.pay_sat, total: total)
                    if result["state"] as? String == "not_sent" {
                        try model.update(record.id) { $0.submitted = false; $0.fundingState = "not_sent" }
                        message = "Not sent. Review the funding fees again."
                    }
                } catch { message = "XBT payment outcome is not confirmed. Check status before another attempt." }
                store.busy = false; await store.engine.releaseMaintenanceWallet()
                await store.refreshCachedArkBalance()
            } else {
                guard let node, let connection = nodeConnection, let review = fundingReview,
                      let data = try WalletKeychain.read("lightning-connection-v1"),
                      try JSONDecoder().decode(LightningConnection.self, from: data) == connection,
                      payments.pending == nil else { throw WalletFailure(message: "Node connection changed. Review again.") }
                let decoded = try LightningPaymentReview.decode(await node.decode(record.quote.hold_invoice), implementation: connection.implementation)
                guard decoded == review else { throw BridgeError.invalidQuote }
                _ = try record.quote.validate(target: BridgeInvoice(record.target))
                // Journal the attempt before either the node request or a possible timeout.
                try model.beginSubmission(record, connection: connection)
                do { try payments.record(PendingNodePayment(invoice: record.quote.hold_invoice, hash: record.id)) }
                catch { try model.update(record.id) { $0.submitted = false; $0.fundingState = "not_sent" }; throw error }
                payments.useNode(node); reviewedTotal = nil
                do {
                    let data = try await node.pay(record.quote.hold_invoice, maximumFee: total - record.quote.pay_sat)
                    try payments.submissionResult(data, hash: record.id, implementation: connection.implementation)
                } catch {
                    if (try? payments.submissionRejected(error, hash: record.id)) == true {
                        try model.update(record.id) { $0.fundingState = "failed" }
                        message = payments.status
                    } else { message = "XBT payment outcome is not confirmed. Checking without resending." }
                }
                payments.submissionFinished(); await payments.checkNow()
            }
            if let updated = model.current { await checkFunding(updated) }
            await model.refreshStatus()
        }
    }
    private func checkFunding(_ record: BridgePaymentRecord) async {
        guard record.submitted else { return }
        do {
            if record.source == .ark {
                guard record.walletID == store.walletID, !store.busy else { return }
                let result = try await store.engine.operation("check_payment", fields: ["payment_hash": record.id])
                let state = result["state"] as? String ?? "unknown"
                try model.update(record.id) { $0.fundingState = state }
                await store.refreshCachedArkBalance()
            } else {
                let (node, config) = try await connectedNode()
                guard record.nodeEndpoint == config.endpoint, record.nodeImplementation == config.implementation.rawValue else {
                    throw WalletFailure(message: "Reconnect the original XBT node to check funding.")
                }
                let result = try await node.payments(hash: record.id)
                if let terminal = try LightningPaymentState.terminalState(in: result, hash: record.id, implementation: config.implementation) {
                    try model.update(record.id) { $0.fundingState = terminal == "succeeded" ? "paid" : "failed" }
                }
            }
        } catch { message = "Funding status is unavailable. No payment was resent." }
    }
}

/// Small, directional service indicator. Never changes or retries a payment.
struct BridgeStatusBadge: View {
    var direction: BridgeDirection? = nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var model = LightningBridgeModel.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let pay = (model.serviceHealth[.paySpamcoin] ?? BridgeHealth(checking: true)).state()
            let receive = (model.serviceHealth[.receiveXBT] ?? BridgeHealth(checking: true)).state()
            let state = direction == .paySpamcoin ? pay : direction == .receiveXBT ? receive : BridgeHealthState.combined(pay, receive)
            HStack(spacing: 5) {
                Image(systemName: state == .live ? "checkmark.circle.fill" : state == .paused ? "pause.circle.fill" : state == .limited ? "circle.lefthalf.filled" : state == .checking ? "clock" : "questionmark.circle")
                Text(state.title)
            }.font(.caption.weight(.medium))
                .foregroundStyle(state == .live ? (colorScheme == .dark ? Color.green : Color(red: 0.07, green: 0.42, blue: 0.23)) : state == .paused || state == .limited ? (colorScheme == .dark ? PaperclipTheme.orange : Color(red: 0.58, green: 0.22, blue: 0.02)) : PaperclipTheme.muted)
                .padding(.horizontal, 8).padding(.vertical, 5).background(.primary.opacity(0.05), in: Capsule())
                .accessibilityElement(children: .ignore).accessibilityLabel("Bridge service: " + state.title)
                .accessibilityHint("Service availability, not payment status")
                .accessibilityIdentifier("bridge-service-status")
        }.task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if direction != .receiveXBT { await model.refreshAvailability(direction: .paySpamcoin) }
                if direction != .paySpamcoin { await model.refreshAvailability(direction: .receiveXBT) }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
}
