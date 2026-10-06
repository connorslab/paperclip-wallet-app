import SwiftUI
import CoreImage.CIFilterBuiltins
import PaperclipMobile

struct SendView: View {
    @EnvironmentObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var onchain = true
    @State private var destination = ""
    @State private var amount = ""
    @State private var total: UInt64?
    @State private var fee: UInt64?
    @State private var confirmation = false
    @State private var submitted = false
    var body: some View {
        Form {
            Section("Pay from") {
                Picker("Wallet", selection: $onchain) { Text("On-chain").tag(true); Text("Ark").tag(false) }.pickerStyle(.segmented)
                TextField(onchain ? "XBT address" : "Ark address, invoice, offer, or XBT address", text: $destination, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Amount in sats", text: $amount).keyboardType(.numberPad)
                Text(onchain ? "Signed with unified sighash for XBT replay protection." : "An XBT address uses an Ark offboard. A Lightning invoice pays from your Ark balance.").font(.caption)
            }
            Section {
                Button("Review payment") { store.run {
                    total = nil; submitted = false
                    guard let sats = UInt64(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive whole-sat amount.") }
                    let quote = try await store.engine.quote(destination: destination, amount: sats, onchain: onchain)
                    guard let quoted = quote["total_sat"] as? NSNumber else { throw WalletFailure(message: "No valid quote was returned.") }
                    total = quoted.uint64Value; fee = (quote["fee_sat"] as? NSNumber)?.uint64Value
                } }.disabled(store.busy)
            }
            if let total {
                Section("Review") {
                    LabeledContent("Recipient", value: "\(amount) sats")
                    LabeledContent("Fee / reserves", value: "\(fee?.formatted() ?? "—") sats")
                    LabeledContent("Total", value: "\(total.formatted()) sats")
                    Text(destination).font(.caption.monospaced()).textSelection(.enabled)
                    Text("Quote expires after 60 seconds. A changed fee requires a new review.").font(.caption)
                    Button("Confirm payment") { confirmation = true }.disabled(store.busy)
                }
            }
            Section { if store.busy { ProgressView() }; Text(store.message).font(.caption) }
            if submitted { Text("Check Activity before another attempt if the result is pending or uncertain.").font(.caption) }
        }.navigationTitle("Send XBT").toolbar { Button("Done") { dismiss() } }
            .onChange(of: destination) { _, _ in total = nil }
            .onChange(of: amount) { _, _ in total = nil }
            .onChange(of: onchain) { _, _ in total = nil }
            .confirmationDialog("Send this payment?", isPresented: $confirmation) {
                Button("Send payment") { store.run {
                    guard let reviewed = total, let sats = UInt64(amount) else { return }
                    total = nil; submitted = true
                    do {
                        let result = try await store.engine.send(destination: destination, amount: sats, total: reviewed, onchain: onchain)
                        store.message = "Payment: \(result["state"] ?? "unknown"). Check Activity for confirmation."
                    } catch { store.message = "Payment outcome is uncertain: \(error.localizedDescription). Check Activity before retrying." }
                } }
            } message: { Text("\(destination)\nTotal: \(total?.formatted() ?? "—") sats") }
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
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
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
                if !value.isEmpty { ReceiveCode(value: value) }
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
            }.padding(24)
        }.background(PaperclipTheme.navy).navigationTitle("Receive XBT").toolbar { Button("Done") { dismiss() } }
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
    var body: some View {
        Form {
            Section("Board from on-chain") {
                Text("Move on-chain XBT onto Ark. Your board becomes spendable after the required confirmations.")
                TextField("Amount in sats", text: $amount).keyboardType(.numberPad)
                Button("Review board") { store.run {
                    boardTotal = nil
                    guard let sats = UInt64(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive amount.") }
                    let quote = try await store.engine.operation("quote_board", fields: ["amount_sat": sats])
                    boardTotal = (quote["total_sat"] as? NSNumber)?.uint64Value
                    boardNet = (quote["net_sat"] as? NSNumber)?.uint64Value
                } }
                if let boardTotal {
                    LabeledContent("Total on-chain debit", value: "\(boardTotal.formatted()) sats")
                    LabeledContent("Ark amount after reserves", value: "\(boardNet?.formatted() ?? "—") sats")
                    Button("Confirm board") { action = "board"; confirming = true }
                }
            }
            Section("Receive and offboard") {
                NavigationLink("Receive BOLT11 or BOLT12 onto Ark") { ReceiveView() }
                NavigationLink("Offboard to an XBT address") { SendView() }
                Text("Select Ark as the payment source to offboard.").font(.caption)
            }
            Section("Seed recovery") {
                if recoveryRequired { Label("Recovery scan required", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                Text("Scan on-chain history and the Ark recovery mailbox. Seed-only recovery may not recover every pending operation. Prefer a full encrypted backup when available.").font(.caption)
                Button("Scan for recoverable XBT") { store.run {
                    let result = try await store.engine.operation("recover")
                    recoveryRequired = false
                    status = "\(result["report"] ?? "Recovery scan completed.")"
                } }
                NavigationLink("Encrypted backup & restore") { BackupView(engine: store.engine) }
            }
            Section("Emergency exit · unilateral recovery") {
                Text("Use this if cooperative Ark offboarding is unavailable. The exit uses saved recovery transactions and a chain backend. Keep on-chain XBT for fees. Confirmations and timelocks can take time.").font(.caption)
                Button("Check exit status") { perform("exit_status") }
                Button("Start emergency exit", role: .destructive) { action = "exit_start"; confirming = true }
                Button("Progress registered exits") { action = "exit_progress"; confirming = true }
                TextField("Claim destination XBT address", text: $exitAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Claim available exits") { action = "exit_claim"; confirming = true }.disabled(exitAddress.isEmpty)
                Text("Use Knots RPC for package relay. You can change your chain backend in Connections without changing keys.").font(.caption)
                Text(status).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section { if store.busy { ProgressView() }; Text(store.message).font(.caption) }
        }.navigationTitle("Ark tools").disabled(store.busy)
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
        List {
            Text("BOLT11 invoices and BOLT12 offer payments use the same persistent claim state. Keep the app open to process payments. Settled payments appear in Activity.").font(.caption)
            ForEach(hashes, id: \.self) { hash in
                VStack(alignment: .leading, spacing: 8) {
                    Text(hash).font(.caption.monospaced()).textSelection(.enabled)
                    Text(states[hash] ?? "Pending")
                    Button("Check status") { store.run {
                        let result = try await store.engine.operation("receive_status", fields: ["payment_hash": hash])
                        states[hash] = result["state"] as? String ?? "unknown"
                    } }
                }
            }
            if hashes.isEmpty { Text("No pending Lightning receives loaded.") }
            Text(store.message).font(.caption)
        }.navigationTitle("Ark Lightning receives")
            .toolbar { Button("Refresh") { refresh() }.disabled(store.busy) }
            .task { refresh() }
    }
    private func refresh() {
        store.run {
            let result = try await store.engine.operation("receive_pending")
            hashes = (result["receives"] as? [[String: Any]] ?? []).compactMap { $0["payment_hash"] as? String }
        }
    }
}
