import SwiftUI
import CoreImage.CIFilterBuiltins
import PaperclipMobile

struct HardwareSendView: View {
    @EnvironmentObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @State private var destination = ""
    @State private var amount = ""
    @State private var prepared: [String: Any]?
    @State private var frames: [String] = []
    @State private var showingQR = false
    @State private var scanningDestination = false
    @State private var scanningSignature = false
    @State private var collector = SigningQRCollector()
    @State private var verifiedID = ""
    @State private var confirming = false
    @State private var submitted = false
    @State private var status = ""
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection {
                Label(store.selectedProfile?.name ?? "Hardware wallet", systemImage: "qrcode").font(.headline)
                Text("Your keys stay on your hardware wallet. Paperclip prepares the payment, then checks its signature before broadcast.")
                    .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                Label("Unified sighash required · 0x21", systemImage: "checkmark.shield").font(.caption).foregroundStyle(PaperclipTheme.orange)
            }
            if prepared == nil {
                WalletSection("1 · Prepare payment") {
                    Button { scanningDestination = true } label: { Label("Scan recipient", systemImage: "qrcode.viewfinder") }
                    TextField("XBT address", text: $destination, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(unit.amountPrompt, text: $amount).keyboardType(.decimalPad)
                    Button("Review payment") {
                        store.run {
                            guard let sats = unit.parse(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive amount.") }
                            let result = try await store.engine.operation("hardware_prepare", fields: ["destination": destination.trimmingCharacters(in: .whitespacesAndNewlines), "amount_sat": sats])
                            guard let text = result["psbt"] as? String, let data = Data(base64Encoded: text) else { throw SigningQRError.invalid }
                            frames = try SigningQR.frames(data); prepared = result; status = ""
                        }
                    }.buttonStyle(.borderedProminent).disabled(store.busy || destination.isEmpty)
                }
            } else {
                WalletSection("Review payment") {
                    Text(destination).font(.caption.monospaced()).textSelection(.enabled)
                    LabeledContent("Recipient receives", value: unit.display((prepared?["amount_sat"] as? NSNumber)?.uint64Value))
                    LabeledContent("Network fee", value: unit.display((prepared?["fee_sat"] as? NSNumber)?.uint64Value))
                    LabeledContent("Total debit", value: unit.display((prepared?["total_sat"] as? NSNumber)?.uint64Value)).font(.headline)
                }
                if verifiedID.isEmpty && !submitted {
                    WalletSection("2 · Sign on your device") {
                        Text("On Krux, choose Sign PSBT. On SeedSigner, choose Scan. Scan the animated request. Verify the recipient, amount, fee, and change on its screen before signing.").font(.subheadline)
                        Button("Show signing QR") { showingQR = true }.buttonStyle(.borderedProminent)
                        Button("Scan signed QR") { collector = SigningQRCollector(); scanningSignature = true }.buttonStyle(.bordered)
                        Text("Scan the signed response directly. Animated UR (SeedSigner), BBQr (Krux), base64, and pNofM are supported. This request expires after 30 minutes.")
                            .font(.caption).foregroundStyle(PaperclipTheme.muted)
                    }
                }
                if !verifiedID.isEmpty && !submitted {
                    WalletSection("3 · Ready to broadcast") {
                        Label("Signatures verified", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                        Text("Every input uses unified SIGHASH_ALL. The transaction matches the payment you reviewed.").font(.subheadline)
                        Text(verifiedID).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Confirm and broadcast") { confirming = true }.buttonStyle(.borderedProminent).disabled(store.busy)
                    }
                }
                if !submitted { Button("Start over", role: .destructive) {
                    store.run {
                        _ = try await store.engine.operation("hardware_cancel")
                        prepared = nil; frames = []; verifiedID = ""; status = ""
                    }
                }.disabled(store.busy) }
            }
            if !status.isEmpty { WalletSection { Text(status).font(.subheadline) } }
            if store.busy { ProgressView("Working…") }
            Text(store.message).font(.caption).foregroundStyle(PaperclipTheme.muted)
        }.padding(22).textFieldStyle(WalletInputStyle()) }.background(PaperclipTheme.navy)
            .navigationTitle("Hardware payment").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .sheet(isPresented: $showingQR) { NavigationStack { SigningQRDisplay(frames: frames) } }
            .fullScreenCover(isPresented: $scanningDestination) { QRScannerView { scanned in
                do {
                    let request = try PaymentInput.scanned(scanned); destination = request.destination
                    if let sats = request.amountSat { amount = unit.input(sats) }
                } catch { status = error.localizedDescription }
            } }
            .fullScreenCover(isPresented: $scanningSignature) {
                QRScannerView(title: "Scan signed transaction", instruction: "Keep the signed QR visible until all frames are collected. Nothing is broadcast yet.") { frame in
                    do {
                        guard let data = try collector.accept(frame) else { return (false, "Read \(collector.received) of \(collector.total) frames") }
                        store.run {
                            let result = try await store.engine.operation("hardware_import", fields: ["signed": data.base64EncodedString()])
                            guard result["verified"] as? Bool == true, let txid = result["txid"] as? String else { throw SigningQRError.invalid }
                            verifiedID = txid; status = "Signed transaction checked. Review it above before broadcasting."
                        }
                        return (true, "Checking signatures")
                    } catch { return (false, error.localizedDescription) }
                }
            }
            .confirmationDialog("Broadcast this signed payment?", isPresented: $confirming) {
                Button("Broadcast payment") {
                    store.run {
                        submitted = true
                        do {
                            let result = try await store.engine.operation("hardware_broadcast", fields: ["txid": verifiedID])
                            status = result["state"] as? String == "submitted" ? "Transaction submitted. Check Activity for confirmations." : "Transaction saved; broadcast is not confirmed. Synchronize and check Activity before making another payment."
                            try? await store.synchronize()
                        } catch { status = "Broadcast was not confirmed: \(error.localizedDescription). Check Activity before starting another payment." }
                    }
                }
            } message: { Text("\(destination)\nTotal: \(unit.display((prepared?["total_sat"] as? NSNumber)?.uint64Value))") }
            .onChange(of: unit) { old, new in if prepared == nil { amount = old.parse(amount).map { new.input($0) } ?? "" } }
    }
}

struct SigningQRDisplay: View {
    let frames: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var paused = false
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    var body: some View {
        ScrollView { VStack(spacing: 22) {
            WalletBrand()
            Text("Scan with your hardware wallet").font(.title2.bold()).multilineTextAlignment(.center)
            if !frames.isEmpty, let image = qr(frames[index]) {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .padding(18).background(.white, in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel("Unsigned signing request, frame \(index + 1) of \(frames.count)")
                Text("BBQr · Frame \(index + 1) of \(frames.count)").font(.caption.monospaced())
                HStack {
                    Button { index = (index + frames.count - 1) % frames.count; paused = true } label: { Image(systemName: "backward.frame") }.accessibilityLabel("Previous frame")
                    Button(paused ? "Play" : "Pause") { paused.toggle() }
                    Button { index = (index + 1) % frames.count; paused = true } label: { Image(systemName: "forward.frame") }.accessibilityLabel("Next frame")
                }.buttonStyle(.bordered)
            }
            Text("This request contains no private keys. Verify every payment detail on your signer, then return to scan its signed response.")
                .font(.subheadline).foregroundStyle(PaperclipTheme.muted).multilineTextAlignment(.center)
        }.padding(24) }.background(PaperclipTheme.navy).navigationTitle("Signing request").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onReceive(timer) { _ in if !paused && frames.count > 1 { index = (index + 1) % frames.count } }
    }
    private func qr(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
