import SwiftUI
import CoreImage.CIFilterBuiltins
import PaperclipMobile

struct SendView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var onchain = true
    @State private var destination = ""
    @State private var amount = ""
    @State private var sendMax = false
    @State private var reviewedAmount: UInt64?
    @State private var total: UInt64?
    @State private var fee: UInt64?
    @State private var needsAmount = false
    @State private var confirmation = false
    @State private var submitted = false
    @State private var scanning = false
    @State private var outcome = "Checking payment outcome"
    @State private var status = ""
    init(onchain: Bool = true) { _onchain = State(initialValue: onchain) }
    private var target: String { PaymentInput.normalized(destination) }
    private var invoice: Bool { !onchain && PaymentInput.isBolt11(destination) }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletSection("Pay from") {
                    Picker("Wallet", selection: $onchain) { Text("On-chain").tag(true); Text("Ark").tag(false) }.pickerStyle(.segmented).disabled(store.busy || submitted)
                    LabeledContent("Balance", value: unit.display(onchain ? store.onchain : store.ark)).font(.headline)
                    USDValue(sats: onchain ? store.onchain : store.ark, mainnet: store.network == "xbt-mainnet")
                    if onchain { Text(store.onchainAccount == "segwit" ? "SegWit account" : "Taproot account").font(.caption).foregroundStyle(PaperclipTheme.muted) }
                    Text(onchain ? "Send XBT to an on-chain address." : "Pay Lightning invoices, BOLT12 offers, Ark addresses, or withdraw to on-chain.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                }
                WalletSection("Recipient") {
                    if !onchain && !submitted {
                        Menu {
                            ForEach(store.profiles.filter { $0.kind == .hardware && $0.network == store.network }) { profile in
                                Button(profile.name) { store.run {
                                    destination = try await store.engine.hardwareReceiveAddress(walletID: profile.id)
                                } }
                            }
                        } label: { Label("Withdraw to a saved QR wallet", systemImage: "qrcode") }
                            .disabled(store.busy || !store.profiles.contains { $0.kind == .hardware && $0.network == store.network })
                        Text("Offboarding to a hardware address does not need a hardware signature. Verify the receiving address on your signer, then review the withdrawal here.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    }
                    Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                        .disabled(store.busy || submitted)
                    TextField(onchain ? "XBT address" : "Paste an invoice, offer, or address", text: $destination, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(store.busy || submitted)
                    if !invoice || needsAmount {
                        if sendMax { Text("Maximum after fees").font(.headline) }
                        else { TextField(unit.amountPrompt, text: $amount).keyboardType(.decimalPad).disabled(store.busy || submitted) }
                        if onchain {
                            Button(sendMax ? "Use a specific amount" : "Send Max") { sendMax.toggle(); reset() }.disabled(store.busy || submitted)
                            if sendMax { Text("Uses all spendable coins in the selected account, minus the network fee. Reserved or immature funds may remain. Review the final amount below.").font(.caption).foregroundStyle(PaperclipTheme.muted) }
                        }
                        if needsAmount { Text("This request has no fixed amount. Choose the amount to send.").font(.caption) }
                    } else {
                        Label("Amount comes from the invoice", systemImage: "bolt.fill").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    }
                    Button { review() } label: { Text("Review payment").frame(maxWidth: .infinity) }.buttonStyle(WalletPrimaryButtonStyle())
                        .disabled(store.busy || target.isEmpty || submitted)
                }
                if let total, let reviewedAmount {
                    WalletSection("Review payment") {
                        LabeledContent("From", value: onchain ? "On-chain wallet" : "Ark balance")
                        LabeledContent("Recipient receives", value: unit.display(reviewedAmount))
                        LabeledContent("Fee / recovery funding", value: unit.display(fee))
                        Divider()
                        LabeledContent("Total debit", value: unit.display(total)).font(.headline)
                        Text(target).font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                        Text("Review is valid for 60 seconds. If costs change, review again.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                        Button("Confirm payment") { confirmation = true }.buttonStyle(WalletPrimaryButtonStyle()).disabled(store.busy)
                    }
                }
                if store.busy || !status.isEmpty {
                    WalletSection { if store.busy { ProgressView("Working…") }; Text(status).font(.subheadline).textSelection(.enabled) }
                }
                if submitted {
                    WalletSection {
                        Label(outcome, systemImage: "clock")
                        Text("Check Activity for the final result before making another attempt.").font(.subheadline)
                        Button("Done") { dismiss() }.modifier(GlassAction())
                    }
                }
            }.padding(22).textFieldStyle(WalletInputStyle())
        }.background(WalletBackdrop()).navigationTitle(onchain ? "Send XBT" : "Pay from Ark")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } } }
            .task {
                if let overview = try? await store.engine.onchainOverview() { store.onchain = (overview["total_sat"] as? NSNumber)?.uint64Value }
            }
            .fullScreenCover(isPresented: $scanning) {
                QRScannerView { value in
                    do {
                        let request = try PaymentInput.scanned(value)
                        sendMax = false
                        destination = request.destination
                        amount = request.amountSat.map { unit.input($0) } ?? ""
                        status = "Scanned. Review the recipient and amount before sending."
                    } catch { status = error.localizedDescription }
                }
            }
            .onChange(of: unit) { old, new in amount = old.parse(amount).map { new.input($0) } ?? ""; reset() }
            .onChange(of: destination) { _, _ in reset(); needsAmount = false }
            .onChange(of: amount) { _, _ in reset() }
            .onChange(of: onchain) { _, _ in reset(); needsAmount = false; sendMax = false }
            .confirmationDialog("Send this payment?", isPresented: $confirmation) {
                Button("Send payment") { send() }
            } message: { Text("Total debit: \(unit.display(total)) from \(onchain ? "on-chain" : "Ark").") }
    }
    private func reset() { total = nil; reviewedAmount = nil; status = "" }
    private func review() {
        let recipient = target, source = onchain, entered = amount, selectedUnit = unit
        store.run {
            do {
                total = nil
                var sats = selectedUnit.parse(entered)
                if !source {
                    let parsed = try await store.engine.operation("inspect_payment", fields: ["destination": recipient])
                    if let fixed = parsed["amount_sat"] as? NSNumber { sats = fixed.uint64Value }
                    else if sats == nil || (PaymentInput.isBolt11(recipient) && !needsAmount) {
                        needsAmount = true; status = "Enter the amount, then review your payment."; return
                    }
                }
                let quote: [String: Any]
                if source && sendMax {
                    quote = try await store.engine.operation("quote_onchain", fields: ["destination": recipient, "send_max": true])
                    sats = (quote["amount_sat"] as? NSNumber)?.uint64Value
                } else {
                    guard let value = sats, value > 0 else { throw WalletFailure(message: "Enter a positive amount. XBT supports up to 8 decimal places.") }
                    quote = try await store.engine.quote(destination: recipient, amount: value, onchain: source)
                }
                guard let sats, sats > 0 else { throw WalletFailure(message: "No spendable amount after fees.") }
                guard recipient == target, source == onchain, entered == amount, selectedUnit == unit else { return }
                guard let quoted = quote["total_sat"] as? NSNumber else { throw WalletFailure(message: "No valid quote was returned.") }
                reviewedAmount = sats; total = quoted.uint64Value; fee = (quote["fee_sat"] as? NSNumber)?.uint64Value
                status = ""
            } catch { status = error.localizedDescription }
        }
    }
    private func send() {
        guard let reviewed = total, let sats = reviewedAmount else { return }
        let recipient = target, source = onchain
        store.run {
            total = nil; submitted = true; outcome = "Checking payment outcome"
            do {
                let result = try await store.engine.send(destination: recipient, amount: sats, total: reviewed, onchain: source)
                if result["state"] as? String == "not_sent" {
                    submitted = false
                    status = "Not sent: \(result["reason"] ?? "Review a new quote.")"
                    return
                }
                outcome = result["state"] as? String == "completed" ? "Payment completed" : "Payment submitted"
                status = "Payment status: \(result["state"] ?? "unknown")."
                try? await store.refreshActivity()
            } catch { status = "Payment outcome needs checking: \(error.localizedDescription). Check Activity before retrying." }
        }
    }
}

struct ReceiveView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var route = 0
    @State private var amount = ""
    @State private var value = ""
    @State private var paymentHash = ""
    @State private var receiveStatus = ""
    @State private var offerDescription = "Paperclip wallet"
    @State private var offerActive = false
    @State private var choosingMethod = false
    private let methodNames = ["On-chain", "Ark transfer", "Lightning invoice", "Lightning offer"]
    private let methodIcons = ["bitcoinsign.circle", "arrow.left.arrow.right", "bolt.fill", "bolt.circle"]
    private let methodDetails = [
        "Receive XBT from an exchange or another on-chain wallet. Funds arrive after network confirmation.",
        "Receive directly from another Ark wallet into your Ark balance.",
        "Request a specific amount with a BOLT11 invoice. Your payment arrives in Ark.",
        "Share a reusable BOLT12 offer. Incoming Lightning payments arrive in Ark."
    ]
    init(route: Int = 0) { _route = State(initialValue: route) }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                WalletBrand()
                VStack(alignment: .leading, spacing: 8) {
                    Text(value.isEmpty ? "Receive with Paperclip" : "Ready to receive")
                        .font(.title2.bold())
                    Text(value.isEmpty ? "Choose how you’d like to receive. We’ll prepare an address or payment request to share." : "Let the sender scan your code, or copy and share the request below.")
                        .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if value.isEmpty {
                WalletSection {
                    Button { choosingMethod = true } label: {
                        WalletNavigationRow(methodNames[route], subtitle: "Change receive method", icon: methodIcons[route])
                    }.buttonStyle(.plain).disabled(store.busy || !store.supportsArk)
                    Text(methodDetails[route]).font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                }
                }
                if value.isEmpty {
                WalletSection(route >= 2 ? "Payment request" : "Your receiving address") {
                if route < 2 {
                    Text(route == 0 ? "Create an address controlled by your wallet. Only send XBT on the matching network." : "Create an Ark address to share with the sender.")
                        .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                }
                if route >= 2 { TextField(route == 3 ? unit.amountPrompt + " (optional)" : unit.amountPrompt, text: $amount).keyboardType(.decimalPad).textFieldStyle(WalletInputStyle()) }
                if route == 3 {
                    TextField("Offer description", text: $offerDescription).textFieldStyle(WalletInputStyle())
                    Button("Load saved BOLT12 offer") { store.run {
                        let result = try await store.engine.operation("offer_status")
                        offerActive = result["active"] as? Bool == true
                        value = offerActive ? (result["offer"] as? String ?? "") : ""
                        receiveStatus = offerActive ? "Saved offer is active." : "No active offer."
                    } }
                }
                Button(route == 3 ? "Create reusable BOLT12 offer" : route == 2 ? "Create BOLT11 invoice" : "Create receive address") { store.run {
                    value = ""
                    if route == 3 {
                        var fields: [String: Any] = ["description": offerDescription]
                        if !amount.isEmpty {
                            guard let sats = unit.parse(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive amount or leave it blank.") }
                            fields["amount_sat"] = sats
                        }
                        let result = try await store.engine.operation("offer_create", fields: fields)
                        value = result["offer"] as? String ?? ""
                        offerActive = result["active"] as? Bool == true
                        await store.engine.setForeground(true)
                    } else if route == 2 {
                        guard let sats = unit.parse(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive amount.") }
                        let result = try await store.engine.operation("receive_lightning", fields: ["amount_sat": sats])
                        value = result["invoice"] as? String ?? ""
                        paymentHash = result["payment_hash"] as? String ?? ""
                    } else { value = try await store.engine.address(ark: route == 1) }
                } }.buttonStyle(WalletPrimaryButtonStyle()).disabled(store.busy)
                if route == 0 { NavigationLink("View on-chain addresses") { OnchainAddressesView() } }
                }
                }
                if !value.isEmpty {
                    WalletSection {
                        HStack {
                            Label(methodNames[route], systemImage: methodIcons[route]).font(.headline)
                            Spacer()
                            Text(store.network == "xbt-mainnet" ? "XBT MAINNET" : "TEST NETWORK")
                                .font(.caption2.bold()).foregroundStyle(PaperclipTheme.muted)
                        }
                        ReceiveCode(value: value).frame(maxWidth: .infinity)
                        if route == 0 {
                            Text("Only send XBT to this address. SHA256 Bitcoin (BTC) is a different network.")
                                .font(.caption).foregroundStyle(PaperclipTheme.muted)
                        }
                    }
                    Button("Create another request") { value = ""; paymentHash = ""; receiveStatus = "" }
                        .disabled(store.busy)
                }
                if route >= 2 {
                    Label("Keep Paperclip open and connected while receiving Lightning payments into Ark. You can check issued invoices in Receive activity.", systemImage: "info.circle").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    if !paymentHash.isEmpty {
                        Button("Check invoice status") { store.run {
                            let result = try await store.engine.operation("receive_status", fields: ["payment_hash": paymentHash])
                            receiveStatus = result["state"] as? String ?? "unknown"
                        } }
                    }
                    if route == 3 && offerActive {
                        Button("Disable this offer", role: .destructive) { store.run {
                            _ = try await store.engine.operation("offer_disable")
                            value = ""; offerActive = false; receiveStatus = "Offer disabled. Issued invoices remain tracked."
                        } }
                    }
                    NavigationLink("Receive activity") { ArkLightningReceivesView() }
                    Text(receiveStatus).font(.caption)
                }
                if store.busy { ProgressView() }
                Text(store.message).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WalletBackdrop()).navigationTitle("Receive XBT").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } } }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $choosingMethod) {
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 16) {
                            Text("Where should your XBT arrive?").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(0..<(store.supportsArk ? 4 : 1)) { method in
                                Button {
                                    route = method
                                    choosingMethod = false
                                } label: {
                                    WalletCard {
                                        HStack {
                                            Label(methodNames[method], systemImage: methodIcons[method]).font(.headline)
                                            Spacer()
                                            if route == method { Image(systemName: "checkmark.circle.fill").foregroundStyle(PaperclipTheme.orange) }
                                        }
                                        Text(methodDetails[method]).font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding(24)
                    }.background(WalletBackdrop()).navigationTitle("Receive method")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Done") { choosingMethod = false } }
                }.presentationDragIndicator(.visible)
            }
            .onChange(of: unit) { old, new in amount = old.parse(amount).map { new.input($0) } ?? ""; value = "" }
            .onChange(of: route) { _, _ in value = ""; paymentHash = ""; receiveStatus = ""; offerActive = false }
            .onChange(of: amount) { _, _ in if route >= 2 { value = ""; paymentHash = "" } }
    }
}

struct ReceiveCode: View {
    let value: String
    var imageAsset: String? = nil
    @State private var copied = false
    var body: some View {
        VStack(spacing: 20) {
            if let image = qr {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 280)
                    .padding(18).background(.white, in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("Receive QR code")
            }
            DisclosureGroup("View full address or request") {
                Text(value).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption).tint(PaperclipTheme.muted)
            HStack {
                Button(copied ? "Copied" : "Copy") { copied = true; UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]) }
                ShareLink(item: value)
            }.buttonStyle(.bordered).controlSize(.large)
        }.onChange(of: value) { _, _ in copied = false }
    }
    private var qr: UIImage? {
        if let imageAsset { return UIImage(named: imageAsset) }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct ArkToolsView: View {
    enum Page { case boarding, recovery, exit
        var title: String { switch self { case .boarding: "Add to Ark"; case .recovery: "Ark recovery"; case .exit: "Emergency exit" } }
    }
    var page: Page = .recovery
    @State private var claimableCount = 0
    @State private var exitSummary = "Check status to see registered exits and claim availability."
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @EnvironmentObject var store: WalletStore
    @State private var recoveryRequired = false
    @State private var amount = ""
    @State private var exitAddress = ""
    @State private var status = ""
    @State private var action: String?
    @State private var confirming = false
    @State private var boardTotal: UInt64?
    @State private var boardNet: UInt64?
    @State private var boardReserve: UInt64?
    @State private var boardNetworkFee: UInt64?
    @State private var boardDeposit: UInt64?
    @State private var boardAnchor: UInt64?
    @State private var boardMinerReserve: UInt64?
    @State private var boardFeeThreshold: UInt64?
    var body: some View {
        ScrollView {
          VStack(spacing: 20) {
            if page == .boarding {
            NavigationLink { HardwareBoardView() } label: {
                WalletCard { WalletNavigationRow("Board from a QR wallet", subtitle: "Sign funding on Krux or SeedSigner", icon: "qrcode") }
            }.buttonStyle(.plain)
            WalletSection("Board from on-chain") {
                Text("Add XBT to your Ark balance") .font(.title3.bold())
                Text("Enter the amount to move from on-chain into Ark. This is the deposit amount, not the spendable balance you will receive.").font(.subheadline)
                DisclosureGroup("How boarding fees work") {
                    Text("1. Network fee: added to your deposit and paid from the on-chain wallet to get the funding transaction confirmed.")
                    Text("2. Recovery funding: deducted from the deposit. It funds the recovery anchor and a reserved miner fee, so this portion is not available to spend in Ark.")
                    Text("The recovery anchor is the larger of the server’s boarding fee and the protocol’s minimum anchor. The server fee is not charged again on top of that anchor.")
                    Text("Small deposits can leave little spendable XBT because recovery funding has a minimum. The deduction is not all operator revenue. Later Ark payments and withdrawals may require additional recovery funding and fees.")
                    Text("The app uses the backend’s regular network fee estimate. Custom fee rates and a guaranteed maximum spendable amount are not available. Review the actual amounts below; quotes expire after 60 seconds.")
                }.font(.subheadline)
                Text("On-chain debit = deposit + network fee. Spendable Ark = deposit − recovery funding.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                TextField(unit.amountPrompt, text: $amount).keyboardType(.decimalPad)
                Button("Review board") { store.run {
                    boardTotal = nil
                    guard let sats = unit.parse(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive amount.") }
                    let quote = try await store.engine.operation("quote_board", fields: ["amount_sat": sats])
                    boardTotal = (quote["total_sat"] as? NSNumber)?.uint64Value
                    boardNet = (quote["net_sat"] as? NSNumber)?.uint64Value
                    boardReserve = (quote["reserve_sat"] as? NSNumber)?.uint64Value
                    boardNetworkFee = (quote["network_fee_sat"] as? NSNumber)?.uint64Value
                    boardDeposit = (quote["board_amount_sat"] as? NSNumber)?.uint64Value
                    boardAnchor = (quote["recovery_anchor_sat"] as? NSNumber)?.uint64Value
                    boardMinerReserve = (quote["recovery_miner_fee_sat"] as? NSNumber)?.uint64Value
                    boardFeeThreshold = (quote["boarding_fee_sat"] as? NSNumber)?.uint64Value
                } }
                if let boardTotal {
                    Divider()
                    LabeledContent("Deposit into Ark", value: unit.display(boardDeposit))
                    LabeledContent("Network fee · added", value: unit.display(boardNetworkFee))
                    LabeledContent("Leaves on-chain wallet", value: unit.display(boardTotal)).font(.headline)
                    Divider()
                    LabeledContent("Recovery funding · deducted", value: unit.display(boardReserve))
                    LabeledContent("Spendable in Ark", value: unit.display(boardNet)).font(.headline)
                    DisclosureGroup("Recovery funding breakdown") {
                        LabeledContent("Funded recovery anchor", value: unit.display(boardAnchor))
                        LabeledContent("Reserved recovery miner fee", value: unit.display(boardMinerReserve))
                        LabeledContent("Server fee threshold · included", value: unit.display(boardFeeThreshold))
                        Text("The server fee threshold is included in the anchor above, not an extra deduction. Recovery funding is not spendable Ark balance or a guaranteed refund.").font(.caption)
                    }
                    if let net = boardNet, boardTotal > 0 {
                        Text("\(unit.display(boardTotal - min(net, boardTotal))) goes to network fees and reserved recovery funding (\(Int((Double(boardTotal - min(net, boardTotal)) / Double(boardTotal) * 100).rounded()))% of the on-chain debit).")
                            .font(.caption).foregroundStyle(PaperclipTheme.muted)
                    }
                    Text("Requires the server’s boarding confirmations. Quote expires after 60 seconds.").font(.caption)
                    Button("Confirm board") { action = "board"; confirming = true }
                }
            }
            }
            if page == .recovery {
            WalletSection("Seed recovery") {
                if recoveryRequired { Label("Recovery scan required", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                Text("Scan on-chain history and the Ark recovery mailbox. Seed-only recovery may not recover every pending operation. Prefer a full encrypted backup when available.").font(.caption)
                Button("Scan for recoverable XBT") { store.run {
                    let result = try await store.engine.operation("recover")
                    recoveryRequired = result["state"] as? String != "recovered"
                    store.onchain = (result["onchain_sat"] as? NSNumber)?.uint64Value
                    status = "\(result["report"] ?? "Recovery scan completed.")"
                } }
                NavigationLink("Encrypted backup & restore") { BackupView(engine: store.engine) }
            }
            WalletSection("Advanced recovery") {
                NavigationLink { ArkToolsView(page: .exit) } label: {
                    WalletNavigationRow("Emergency exit", subtitle: "Unilateral recovery when the server is unavailable", icon: "exclamationmark.shield")
                }
            }
            }
            if page == .exit {
            WalletSection("Emergency exit · unilateral recovery") {
                Text("Use this if cooperative Ark offboarding is unavailable. The exit uses saved recovery transactions and a chain backend. Keep on-chain XBT for fees. Confirmations and timelocks can take time.").font(.caption)
                Button("Check exit status") { perform("exit_status") }
                Button("Start emergency exit", role: .destructive) { action = "exit_start"; confirming = true }
                Button("Progress registered exits") { action = "exit_progress"; confirming = true }
                TextField("Claim destination XBT address", text: $exitAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Claim available exits") { action = "exit_claim"; confirming = true }.disabled(exitAddress.isEmpty || claimableCount == 0)
                Text("Use an Ark-capable Electrum server or your own Knots RPC for package relay. Change backends in Connections without changing keys.").font(.caption)
                Text(exitSummary).font(.subheadline)
                if !status.isEmpty { DisclosureGroup("Technical details") { Text(status).font(.caption.monospaced()).textSelection(.enabled) } }
            }
            }
            if page != .exit && !status.isEmpty { WalletSection { Text(status).font(.caption).textSelection(.enabled) } }
            WalletSection { if store.busy { ProgressView() }; Text(store.message).font(.caption) }
          }.padding(22).textFieldStyle(WalletInputStyle())
        }.background(WalletBackdrop()).navigationTitle(page.title).disabled(store.busy)
            .task {
                recoveryRequired = UserDefaults.standard.bool(forKey: "seedRecoveryRequired-" + store.walletID)
                    || (store.walletID == "legacy" && UserDefaults.standard.bool(forKey: "seedRecoveryRequired"))
                if page == .exit { perform("exit_status") }
            }
            .onChange(of: recoveryRequired) { _, value in
                UserDefaults.standard.set(value, forKey: "seedRecoveryRequired-" + store.walletID)
                if store.walletID == "legacy" { UserDefaults.standard.set(value, forKey: "seedRecoveryRequired") }
            }
            .onChange(of: amount) { _, _ in boardTotal = nil }
            .onChange(of: unit) { old, new in amount = old.parse(amount).map { new.input($0) } ?? ""; boardTotal = nil }
            .confirmationDialog("Confirm Ark operation", isPresented: $confirming) {
                Button(action == "board" ? "Board XBT" : "Continue", role: action == "exit_start" ? .destructive : nil) {
                    if let action { perform(action) }
                }
            } message: {
                Text(action == "board" ? "Debit \(unit.display(boardTotal)) from on-chain. Receive \(unit.display(boardNet)) on Ark after confirmation." : "This operation can register or broadcast recovery transactions and incur on-chain fees. Claim destination: \(exitAddress)")
            }
    }
    private func perform(_ op: String) {
        store.run {
            var fields: [String: Any] = ["confirmed": true]
            if op == "board" {
                guard let sats = unit.parse(amount), let total = boardTotal else { return }
                fields["amount_sat"] = sats; fields["total_sat"] = total; boardTotal = nil
            }
            if op == "exit_claim" { fields["destination"] = exitAddress }
            do {
                let result = try await store.engine.operation(op, fields: fields)
                if op.hasPrefix("exit_") {
                    let snapshot = op == "exit_status" ? result : try await store.engine.operation("exit_status")
                    claimableCount = (snapshot["claimable_count"] as? NSNumber)?.intValue ?? 0
                    let exits = snapshot["exits"] as? [String] ?? []
                    if claimableCount > 0 { exitSummary = "\(claimableCount) exit(s) can be claimed. Enter your on-chain destination below." }
                    else if exits.isEmpty { exitSummary = "No emergency exits are registered. Your available Ark balance has not been moved into an exit. For a normal withdrawal, use Withdraw to on-chain." }
                    else if let height = snapshot["claimable_height"] as? NSNumber { exitSummary = "Waiting for confirmations and timelocks. All exits are expected to be claimable at block \(height). Progress registered exits to update their state." }
                    else { exitSummary = "Exits are registered but not claimable yet. Progress them to broadcast the required recovery transactions and update confirmations." }
                }
                status = String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
            } catch { store.message = "\(error.localizedDescription) Check status before another attempt." }
        }
    }
}

struct ArkLightningReceivesView: View {
    @EnvironmentObject var store: WalletStore
    @State private var hashes: [String] = []
    @State private var states: [String: String] = [:]
    var body: some View {
        ScrollView {
          VStack(spacing: 20) {
            Text("BOLT11 invoices and BOLT12 offer payments use the same persistent claim state. Keep the app open to process payments. Settled payments appear in Activity.").font(.caption)
            ForEach(hashes, id: \.self) { hash in
                WalletSection {
                    Text(hash).font(.caption.monospaced()).textSelection(.enabled)
                    Text((states[hash] ?? "Pending").replacingOccurrences(of: "_", with: " ").capitalized)
                    Button("Check status") { check(hash, claim: false) }
                    Button("Retry claim") { check(hash, claim: true) }.disabled(store.busy)
                }
            }
            if hashes.isEmpty { Text("No pending Lightning receives loaded.") }
            Text(store.message).font(.caption)
          }.padding(22)
        }.background(WalletBackdrop()).navigationTitle("Lightning receives")
            .toolbar { Button("Refresh") { refresh() }.disabled(store.busy) }
            .task { refresh() }
    }
    private func check(_ hash: String, claim: Bool) {
        store.run {
            do {
                let result = try await store.engine.operation(claim ? "receive_claim" : "receive_status", fields: ["payment_hash": hash])
                states[hash] = result["state"] as? String ?? "unknown"
            } catch { states[hash] = error.localizedDescription }
        }
    }
    private func refresh() {
        store.run {
            let result = try await store.engine.operation("receive_pending")
            hashes = (result["receives"] as? [[String: Any]] ?? []).compactMap { $0["payment_hash"] as? String }
        }
    }
}

struct OnchainAddressesView: View {
    @EnvironmentObject var store: WalletStore
    @State private var separateChange = false
    @State private var entries: [Entry] = []
    @State private var start = 0
    @State private var change = false
    @State private var hasMore = false
    @State private var loading = false
    @State private var error = ""
    struct Entry: Identifiable {
        let id: Int
        let address: String
        let revealed: Bool
    }
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection {
                if store.supportsArk && !separateChange {
                    Text("Receive & change share the same derivation branch in this wallet. Addresses are shown by derivation index.")
                } else {
                    Picker("Branch", selection: $change) { Text("Receive").tag(false); Text("Change").tag(true) }.pickerStyle(.segmented)
                    Text(change ? "Change returns to this wallet after a payment." : "Receive addresses for this account.")
                }
                Text("Previewing does not reserve addresses. Use Create receive address when requesting a payment so recovery can discover it reliably.").font(.caption)
            }
            WalletSection("Derived addresses") {
                ForEach(entries) { entry in
                    NavigationLink {
                        ScrollView {
                            ReceiveCode(value: entry.address).frame(maxWidth: .infinity).padding(24)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(WalletBackdrop())
                            .navigationTitle("Address #\(entry.id)")
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("#\(entry.id) · \(entry.revealed ? "Revealed" : "Preview")")
                            Text(entry.address).font(.caption.monospaced()).lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            WalletSection {
                HStack {
                    Button("Previous") { start = max(0, start - 20) }.disabled(start == 0 || loading)
                    Spacer()
                    Button("Next") { start += 20 }.disabled(!hasMore || loading)
                }.buttonStyle(.borderless)
                if loading { ProgressView() }
                if !error.isEmpty { Text(error).font(.caption) }
            }
        }.padding(22) }.navigationTitle("On-chain addresses")
            .scrollContentBackground(.hidden).background(WalletBackdrop())
            .onChange(of: change) { _, _ in start = 0 }
            .task(id: "\(start)-\(change)") {
                loading = true; error = ""
                do {
                    let overview = try await store.engine.onchainOverview()
                    separateChange = overview["account"] as? String == "segwit"
                    let page = try await store.engine.onchainAddresses(start: start, change: change)
                    hasMore = page.hasMore
                    entries = page.entries.compactMap { row in
                        guard let index = row["index"] as? Int, let address = row["address"] as? String,
                              let revealed = row["revealed"] as? Bool else { return nil }
                        return Entry(id: index, address: address, revealed: revealed)
                    }
                } catch { entries = []; hasMore = false; self.error = error.localizedDescription }
                loading = false
            }
    }
}
