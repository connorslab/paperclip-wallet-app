import SwiftUI
import PaperclipMobile

struct HardwareBoardView: View {
    @EnvironmentObject var store: WalletStore
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @State private var sourceID = ""
    @State private var amount = ""
    @State private var quote: [String: Any]?
    @State private var frames: [String] = []
    @State private var showingQR = false
    @State private var scanning = false
    @State private var collector = SigningQRCollector()
    @State private var verifiedID = ""
    @State private var confirming = false
    @State private var submitted = false
    @State private var status = ""
    private var sources: [WalletProfile] { store.profiles.filter {
        $0.kind == .hardware && $0.network == store.network &&
        ($0.descriptor?.hasPrefix("wpkh(") == true || $0.descriptor?.hasPrefix("tr(") == true)
    } }
    private var sourceName: String { sources.first { $0.id == sourceID }?.name ?? "Hardware wallet" }
    private func sats(_ key: String) -> UInt64? { (quote?[key] as? NSNumber)?.uint64Value }
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection {
                Label("Hardware wallet → Ark", systemImage: "arrow.down.forward.circle").font(.title2.bold())
                Text("Fund \(store.selectedProfile?.name ?? "this mobile wallet")’s Ark balance with XBT from your QR wallet. Your hardware wallet signs the on-chain funding transaction.")
                Text("After boarding, Ark funds use this mobile wallet’s keys and recovery backup. They are not protected by the hardware signer. Keep some XBT in this mobile wallet’s on-chain balance for emergency recovery fees.")
                    .font(.caption).foregroundStyle(PaperclipTheme.muted)
                NavigationLink("Back up this Ark wallet") { BackupView(engine: store.engine) }
            }
            if sources.isEmpty {
                WalletSection {
                    Text("Add a native SegWit (BIP84) or Taproot (BIP86) QR wallet on this network first.")
                    NavigationLink("Add hardware wallet") { PublicWalletImportView(hardware: true) }
                }
            } else if quote == nil {
                WalletSection("1 · Choose funding") {
                    Picker("From", selection: $sourceID) {
                        Text("Choose a QR wallet").tag("")
                        ForEach(sources) { Text($0.name).tag($0.id) }
                    }
                    TextField("Deposit · " + unit.amountPrompt, text: $amount).keyboardType(.decimalPad)
                    Text("Use a native SegWit (BIP84) or Taproot (BIP86) account. Ark requires a stable funding transaction ID; legacy and nested SegWit accounts cannot board directly.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                    Button("Review boarding") { prepare() }.buttonStyle(.borderedProminent).disabled(sourceID.isEmpty || store.busy)
                }
            }
            if quote != nil {
                WalletSection("Review transfer") {
                    LabeledContent("From", value: sourceName)
                    LabeledContent("To Ark", value: store.selectedProfile?.name ?? "Mobile wallet")
                    LabeledContent("Deposit", value: unit.display(sats("amount_sat")))
                    LabeledContent("Network fee · added", value: unit.display(sats("network_fee_sat")))
                    LabeledContent("Leaves hardware wallet", value: unit.display(sats("total_sat"))).font(.headline)
                    Divider()
                    LabeledContent("Recovery funding · deducted", value: unit.display(sats("reserve_sat")))
                    LabeledContent("Spendable in Ark", value: unit.display(sats("net_sat"))).font(.headline)
                    DisclosureGroup("Fees and recovery funding") {
                        LabeledContent("Recovery anchor", value: unit.display(sats("anchor_sat")))
                        LabeledContent("Reserved miner fee", value: unit.display(sats("miner_fee_sat")))
                        Text("The anchor includes the server’s boarding fee threshold. Recovery funding is deducted once and is not spendable Ark balance. Small deposits may leave little available. Later payments and withdrawals can require more fees and recovery funding.").font(.caption)
                    }
                    Text("Ark funding address").font(.caption.bold())
                    Text(quote?["address"] as? String ?? "").font(.caption.monospaced()).textSelection(.enabled)
                }
                if verifiedID.isEmpty && !submitted {
                    WalletSection("2 · Sign with your hardware wallet") {
                        Text("Scan this request with Krux or SeedSigner. Verify the Ark funding address, deposit, network fee, and change on the signer before approving.")
                        Button("Show signing QR") { showingQR = true }.buttonStyle(.borderedProminent)
                        Button("Scan signed QR") { collector = SigningQRCollector(); scanning = true }.buttonStyle(.bordered)
                        Text("Unified sighash (0x21) is required. The request expires after 30 minutes; fees are checked again before boarding. Scanning does not broadcast.").font(.caption)
                    }
                } else if !submitted {
                    WalletSection("3 · Complete boarding") {
                        Label("Hardware signatures verified", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                        Text("Paperclip saves Ark recovery data before sending the funding transaction. The Ark balance becomes available after the required confirmations.").font(.subheadline)
                        Button("Confirm and board") { confirming = true }.buttonStyle(.borderedProminent).disabled(store.busy)
                    }
                }
                if !submitted { Button("Start over", role: .destructive) {
                    store.run {
                        _ = try await store.engine.operation("ark_hardware_cancel", fields: ["request_id": quote?["request_id"] as? String ?? ""])
                        quote = nil; frames = []; verifiedID = ""; status = ""
                    }
                }.disabled(store.busy) }
            }
            if store.busy { ProgressView("Working…") }
            if !status.isEmpty { WalletSection { Text(status) } }
            Text(store.message).font(.caption).foregroundStyle(PaperclipTheme.muted)
        }.padding(22).textFieldStyle(WalletInputStyle()) }.background(PaperclipTheme.navy)
            .navigationTitle("Board from QR wallet").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingQR) { NavigationStack { SigningQRDisplay(frames: frames) } }
            .fullScreenCover(isPresented: $scanning) {
                QRScannerView(title: "Scan signed boarding", instruction: "Keep the signed QR visible until all frames are collected. Nothing is broadcast yet.") { frame in
                    do {
                        guard let data = try collector.accept(frame) else { return (false, "Read \(collector.received) of \(collector.total) frames") }
                        store.run {
                            let result = try await store.engine.operation("ark_hardware_import", fields: ["signed": data.base64EncodedString()])
                            guard result["verified"] as? Bool == true, let txid = result["txid"] as? String else { throw SigningQRError.invalid }
                            verifiedID = txid
                        }
                        return (true, "Checking signatures")
                    } catch { return (false, error.localizedDescription) }
                }
            }
            .confirmationDialog("Fund this mobile Ark wallet?", isPresented: $confirming) {
                Button("Board XBT") { store.run {
                    submitted = true
                    do {
                        let result = try await store.engine.operation("ark_hardware_commit", fields: ["txid": verifiedID])
                        status = "Boarding submitted. \(unit.display((result["amount_sat"] as? NSNumber)?.uint64Value)) will become available after confirmation. Check Ark activity and save an updated encrypted backup."
                        try? await store.synchronize()
                    } catch {
                        status = "Boarding was not confirmed: \(error.localizedDescription). Check Ark activity and your hardware wallet before making another attempt."
                    }
                } }
            } message: { Text("Debit \(unit.display(sats("total_sat"))) from \(sourceName). Spendable Ark: \(unit.display(sats("net_sat"))). Ark keys stay on this iPhone.") }
            .onDisappear {
                if !scanning && !showingQR && !submitted, let requestID = quote?["request_id"] as? String {
                    quote = nil; frames = []; verifiedID = ""
                    Task { _ = try? await store.engine.operation("ark_hardware_cancel", fields: ["request_id": requestID]) }
                }
            }
            .onChange(of: unit) { old, new in if quote == nil { amount = old.parse(amount).map { new.input($0) } ?? "" } }
    }
    private func prepare() {
        store.run {
            guard let sats = unit.parse(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive deposit amount.") }
            let result = try await store.engine.prepareHardwareBoard(sourceID: sourceID, amount: sats)
            guard let psbt = result["psbt"] as? String, let data = Data(base64Encoded: psbt) else { throw SigningQRError.invalid }
            frames = try SigningQR.frames(data); quote = result; verifiedID = ""; status = ""
        }
    }
}
