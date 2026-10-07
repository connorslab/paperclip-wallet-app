import SwiftUI
import CoreImage.CIFilterBuiltins
import PaperclipMobile

struct SendView: View {
    @EnvironmentObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var onchain = true
    @State private var destination = ""
    @State private var amount = ""
    @State private var reviewedAmount: UInt64?
    @State private var total: UInt64?
    @State private var fee: UInt64?
    @State private var needsAmount = false
    @State private var confirmation = false
    @State private var submitted = false
    @State private var status = ""
    init(onchain: Bool = true) { _onchain = State(initialValue: onchain) }
    private var target: String { PaymentInput.normalized(destination) }
    private var invoice: Bool { !onchain && PaymentInput.isBolt11(destination) }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletSection("Pay from") {
                    Picker("Wallet", selection: $onchain) { Text("On-chain").tag(true); Text("Ark").tag(false) }.pickerStyle(.segmented).disabled(store.busy || submitted)
                    Text(onchain ? "Send XBT to an on-chain address." : "Pay Lightning invoices, BOLT12 offers, Ark addresses, or withdraw to on-chain.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                }
                WalletSection("Recipient") {
                    TextField(onchain ? "XBT address" : "Paste an invoice, offer, or address", text: $destination, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(store.busy || submitted)
                    if !invoice || needsAmount {
                        TextField("Amount in sats", text: $amount).keyboardType(.numberPad).disabled(store.busy || submitted)
                        if needsAmount { Text("This request has no fixed amount. Choose how many sats to send.").font(.caption) }
                    } else {
                        Label("Amount comes from the invoice", systemImage: "bolt.fill").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    }
                    Button { review() } label: { Text("Review payment").frame(maxWidth: .infinity) }.modifier(GlassAction())
                        .disabled(store.busy || target.isEmpty || submitted)
                }
                if let total, let reviewedAmount {
                    WalletSection("Review payment") {
                        LabeledContent("From", value: onchain ? "On-chain wallet" : "Ark balance")
                        LabeledContent("Recipient receives", value: "\(reviewedAmount.formatted()) sats")
                        LabeledContent("Fee / recovery funding", value: "\(fee?.formatted() ?? "—") sats")
                        Divider()
                        LabeledContent("Total debit", value: "\(total.formatted()) sats").font(.headline)
                        Text(target).font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                        Text("Review is valid for 60 seconds. If costs change, review again.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                        Button("Confirm payment") { confirmation = true }.modifier(GlassAction()).disabled(store.busy)
                    }
                }
                if store.busy || !status.isEmpty {
                    WalletSection { if store.busy { ProgressView("Working…") }; Text(status).font(.subheadline).textSelection(.enabled) }
                }
                if submitted {
                    WalletSection {
                        Label("Payment request sent", systemImage: "clock")
                        Text("Check Activity for the final result before making another attempt.").font(.subheadline)
                        Button("Done") { dismiss() }.modifier(GlassAction())
                    }
                }
            }.padding(22).textFieldStyle(.roundedBorder)
        }.background(PaperclipTheme.navy.ignoresSafeArea()).navigationTitle(onchain ? "Send XBT" : "Pay from Ark")
            .toolbar { Button("Done") { dismiss() } }
            .onChange(of: destination) { _, _ in reset(); needsAmount = false }
            .onChange(of: amount) { _, _ in reset() }
            .onChange(of: onchain) { _, _ in reset(); needsAmount = false }
            .confirmationDialog("Send this payment?", isPresented: $confirmation) {
                Button("Send payment") { send() }
            } message: { Text("Total debit: \(total?.formatted() ?? "—") sats from \(onchain ? "on-chain" : "Ark").") }
    }
    private func reset() { total = nil; reviewedAmount = nil; status = "" }
    private func review() {
        let recipient = target, source = onchain, entered = amount
        store.run {
            do {
                total = nil
                var sats = UInt64(entered)
                if !source {
                    let parsed = try await store.engine.operation("inspect_payment", fields: ["destination": recipient])
                    if let fixed = parsed["amount_sat"] as? NSNumber { sats = fixed.uint64Value }
                    else if sats == nil || (PaymentInput.isBolt11(recipient) && !needsAmount) {
                        needsAmount = true; status = "Enter the amount, then review your payment."; return
                    }
                }
                guard let sats, sats > 0 else { throw WalletFailure(message: "Enter a positive whole-sat amount.") }
                let quote = try await store.engine.quote(destination: recipient, amount: sats, onchain: source)
                guard recipient == target, source == onchain, entered == amount else { return }
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
            total = nil; submitted = true
            do {
                let result = try await store.engine.send(destination: recipient, amount: sats, total: reviewed, onchain: source)
                status = "Payment status: \(result["state"] ?? "unknown")."
                try? await store.refreshActivity()
            } catch { status = "Payment outcome needs checking: \(error.localizedDescription). Check Activity before retrying." }
        }
    }
}

struct ReceiveView: View {
    @EnvironmentObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var route = 0
    @State private var amount = ""
    @State private var value = ""
    @State private var paymentHash = ""
    @State private var receiveStatus = ""
    @State private var offerDescription = "Paperclip wallet"
    @State private var offerActive = false
    init(route: Int = 0) { _route = State(initialValue: route) }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                WalletSection("Receive method") {
                Picker("Receive to", selection: $route) { Text("On-chain").tag(0); Text("Ark").tag(1); Text("BOLT11 → Ark").tag(2); Text("BOLT12 → Ark").tag(3) }.pickerStyle(.menu)
                if route >= 2 { TextField(route == 3 ? "Amount in sats (optional)" : "Amount in sats", text: $amount).keyboardType(.numberPad).textFieldStyle(.roundedBorder) }
                if route == 3 {
                    TextField("Offer description", text: $offerDescription).textFieldStyle(.roundedBorder)
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
                            guard let sats = UInt64(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive amount or leave it blank.") }
                            fields["amount_sat"] = sats
                        }
                        let result = try await store.engine.operation("offer_create", fields: fields)
                        value = result["offer"] as? String ?? ""
                        offerActive = result["active"] as? Bool == true
                        await store.engine.setForeground(true)
                    } else if route == 2 {
                        guard let sats = UInt64(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive amount.") }
                        let result = try await store.engine.operation("receive_lightning", fields: ["amount_sat": sats])
                        value = result["invoice"] as? String ?? ""
                        paymentHash = result["payment_hash"] as? String ?? ""
                    } else { value = try await store.engine.address(ark: route == 1) }
                } }.buttonStyle(.borderedProminent).disabled(store.busy)
                if route == 0 { NavigationLink("View on-chain addresses") { OnchainAddressesView() } }
                }
                if !value.isEmpty { WalletSection { ReceiveCode(value: value).frame(maxWidth: .infinity) } }
                if route >= 2 {
                    Text("Keep Paperclip open and online to receive. iOS can suspend the app in the background. BOLT12 requests need the foreground listener; issued invoices remain tracked after you close the screen.").font(.caption)
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
                    NavigationLink("Pending Lightning receives") { ArkLightningReceivesView() }
                    Text(receiveStatus).font(.caption)
                }
                if store.busy { ProgressView() }
                Text(store.message).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PaperclipTheme.navy.ignoresSafeArea()).navigationTitle("Receive XBT").toolbar { Button("Done") { dismiss() } }
            .onChange(of: route) { _, _ in value = ""; paymentHash = ""; receiveStatus = ""; offerActive = false }
            .onChange(of: amount) { _, _ in if route >= 2 { value = ""; paymentHash = "" } }
    }
}

struct ReceiveCode: View {
    let value: String
    var body: some View {
        VStack(spacing: 20) {
            if let image = qr {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 280)
                    .padding(18).background(.white, in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("Receive QR code")
            }
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
            HStack {
                Button("Copy") { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]) }
                ShareLink(item: value)
            }.buttonStyle(.bordered)
        }
    }
    private var qr: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct ArkToolsView: View {
    @EnvironmentObject var store: WalletStore
    @AppStorage("seedRecoveryRequired") private var recoveryRequired = false
    @State private var amount = ""
    @State private var exitAddress = ""
    @State private var status = ""
    @State private var action: String?
    @State private var confirming = false
    @State private var boardTotal: UInt64?
    @State private var boardNet: UInt64?
    @State private var boardReserve: UInt64?
    @State private var boardNetworkFee: UInt64?
    var body: some View {
        ScrollView {
          VStack(spacing: 20) {
            WalletSection("Board from on-chain") {
                Text("Add XBT to your Ark balance") .font(.title3.bold())
                Text("Boarding uses an on-chain transaction. Its network fee is added to the amount you enter; the boarding fee and recovery funding are deducted from that amount before it becomes spendable on Ark.").font(.subheadline)
                Text("Small boards can lose a significant share to these costs. The current app uses the backend’s regular fee estimate; a custom boarding fee rate is not available. Review the net amount before confirming.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                TextField("Amount in sats", text: $amount).keyboardType(.numberPad)
                Button("Review board") { store.run {
                    boardTotal = nil
                    guard let sats = UInt64(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive amount.") }
                    let quote = try await store.engine.operation("quote_board", fields: ["amount_sat": sats])
                    boardTotal = (quote["total_sat"] as? NSNumber)?.uint64Value
                    boardNet = (quote["net_sat"] as? NSNumber)?.uint64Value
                    boardReserve = (quote["reserve_sat"] as? NSNumber)?.uint64Value
                    boardNetworkFee = (quote["network_fee_sat"] as? NSNumber)?.uint64Value
                } }
                if let boardTotal {
                    LabeledContent("Network fee (added)", value: "\(boardNetworkFee?.formatted() ?? "—") sats")
                    LabeledContent("Boarding / recovery deduction", value: "\(boardReserve?.formatted() ?? "—") sats")
                    LabeledContent("Total on-chain debit", value: "\(boardTotal.formatted()) sats")
                    LabeledContent("Available on Ark after confirmation", value: "\(boardNet?.formatted() ?? "—") sats")
                    Text("Requires the server’s boarding confirmations. Quote expires after 60 seconds.").font(.caption)
                    Button("Confirm board") { action = "board"; confirming = true }
                }
            }
            WalletSection("Receive and offboard") {
                NavigationLink("Receive BOLT11 or BOLT12 onto Ark") { ReceiveView(route: 2) }
                NavigationLink("Pending Lightning receives") { ArkLightningReceivesView() }
                NavigationLink("Offboard to an XBT address") { SendView(onchain: false) }
                Text("Receive into your Ark balance or send Ark funds to an on-chain address.").font(.caption)
            }
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
            WalletSection("Emergency exit · unilateral recovery") {
                Text("Use this if cooperative Ark offboarding is unavailable. The exit uses saved recovery transactions and a chain backend. Keep on-chain XBT for fees. Confirmations and timelocks can take time.").font(.caption)
                Button("Check exit status") { perform("exit_status") }
                Button("Start emergency exit", role: .destructive) { action = "exit_start"; confirming = true }
                Button("Progress registered exits") { action = "exit_progress"; confirming = true }
                TextField("Claim destination XBT address", text: $exitAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Claim available exits") { action = "exit_claim"; confirming = true }.disabled(exitAddress.isEmpty)
                Text("Use an Ark-capable Electrum server or your own Knots RPC for package relay. Change backends in Connections without changing keys.").font(.caption)
                Text(status).font(.caption.monospaced()).textSelection(.enabled)
            }
            WalletSection { if store.busy { ProgressView() }; Text(store.message).font(.caption) }
          }.padding(22).textFieldStyle(.roundedBorder)
        }.background(PaperclipTheme.navy.ignoresSafeArea()).navigationTitle("Ark tools").disabled(store.busy)
            .onChange(of: amount) { _, _ in boardTotal = nil }
            .confirmationDialog("Confirm Ark operation", isPresented: $confirming) {
                Button(action == "board" ? "Board XBT" : "Continue", role: action == "exit_start" ? .destructive : nil) {
                    if let action { perform(action) }
                }
            } message: {
                Text(action == "board" ? "Debit \(boardTotal?.formatted() ?? "—") sats from on-chain. Receive \(boardNet?.formatted() ?? "—") sats on Ark after confirmation." : "This operation can register or broadcast recovery transactions and incur on-chain fees. Claim destination: \(exitAddress)")
            }
    }
    private func perform(_ op: String) {
        store.run {
            var fields: [String: Any] = ["confirmed": true]
            if op == "board" {
                guard let sats = UInt64(amount), let total = boardTotal else { return }
                fields["amount_sat"] = sats; fields["total_sat"] = total; boardTotal = nil
            }
            if op == "exit_claim" { fields["destination"] = exitAddress }
            do {
                let result = try await store.engine.operation(op, fields: fields)
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
        }.background(PaperclipTheme.navy.ignoresSafeArea()).navigationTitle("Lightning receives")
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
    @State private var entries: [Entry] = []
    @State private var start = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var error = ""
    struct Entry: Identifiable {
        let id: Int
        let address: String
        let revealed: Bool
    }
    var body: some View {
        List {
            Section {
                Text("Receive & change share the same derivation branch in this wallet. Addresses are shown by derivation index.")
                Text("Previewing does not reserve addresses. Use Create receive address when requesting a payment so recovery can discover it reliably.").font(.caption)
            }
            Section("Derived addresses") {
                ForEach(entries) { entry in
                    NavigationLink {
                        ScrollView {
                            ReceiveCode(value: entry.address).frame(maxWidth: .infinity).padding(24)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(PaperclipTheme.navy.ignoresSafeArea())
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
            Section {
                HStack {
                    Button("Previous") { start = max(0, start - 20) }.disabled(start == 0 || loading)
                    Spacer()
                    Button("Next") { start += 20 }.disabled(!hasMore || loading)
                }.buttonStyle(.borderless)
                if loading { ProgressView() }
                if !error.isEmpty { Text(error).font(.caption) }
            }
        }.navigationTitle("On-chain addresses")
            .scrollContentBackground(.hidden).background(PaperclipTheme.navy)
            .task(id: start) {
                loading = true; error = ""
                do {
                    let page = try await store.engine.onchainAddresses(start: start)
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
