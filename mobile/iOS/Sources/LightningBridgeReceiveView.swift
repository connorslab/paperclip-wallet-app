import SwiftUI
import PaperclipMobile

struct LightningBridgeReceiveView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @ObservedObject private var model = LightningBridgeReceiveModel.shared
    @State private var amount = ""
    @State private var availability: BridgeAvailability?
    @State private var estimate: BridgeEstimate?
    @State private var estimatedHash: String?
    @State private var newRequest = false
    @State private var showingInvoice = false
    private var current: BridgeReceiveRecord? { newRequest ? nil : model.current }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletSection {
                    Label("Paperclip Bridge", systemImage: "arrow.left.arrow.right").font(.headline).foregroundStyle(PaperclipTheme.orange)
                    Text("Receive XBT.\nThey pay Spamcoin (BTC).").font(.title.bold())
                    Text("Create an invoice on your CLN or LND node, then share a Spamcoin (BTC) invoice with the sender. The bridge pays XBT to your node.")
                        .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                }
                if let record = current {
                    requestCard(record)
                } else {
                    WalletSection("Receive on your node") {
                        TextField("Amount to receive in \(unit.title)", text: $amount).keyboardType(.decimalPad)
                            .accessibilityIdentifier("bridge-receive-amount")
                        if let sats = unit.parse(amount) { USDValue(sats: sats) }
                        Text("This is the XBT amount your node receives. The sender covers the bridge conversion and their wallet’s routing fee.")
                            .font(.caption).foregroundStyle(PaperclipTheme.muted)
                        if let info = availability, let min = info.min_sat, let max = info.max_sat {
                            Text("Current range: \(min.formatted(.number.precision(.fractionLength(0...3)))) – \(max.formatted(.number.precision(.fractionLength(0...3)))) XBT sats")
                                .font(.caption).foregroundStyle(PaperclipTheme.muted)
                        }
                        Button("Create XBT invoice & review") { create() }.buttonStyle(WalletPrimaryButtonStyle())
                            .disabled(!model.loaded || unit.parse(amount).map { $0 == 0 } ?? true)
                    }
                }
                if model.busy { ProgressView("Preparing receive request…") }
                if !model.error.isEmpty { WalletSection { Text(model.error).font(.subheadline) } }
                WalletSection {
                    Label("Lightning nodes only", systemImage: "server.rack").font(.headline)
                    Text("Keep your node online with enough inbound channel capacity. Ark does not support receiving through this bridge because its timelocks differ.")
                        .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    Text("USD values are estimates from xbt.live. Spamcoin (BTC) estimates also use the bridge’s quoted exchange rate.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    Text("The bridge receives the invoice and your network connection details. Your node credentials stay on this device.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                    NavigationLink { history } label: {
                        WalletNavigationRow("Receive activity", subtitle: "Saved requests and node confirmations", icon: "clock.arrow.circlepath")
                    }.buttonStyle(.plain)
                }
            }.walletPageContent().textFieldStyle(WalletInputStyle()).disabled(model.busy)
        }.walletPageBackground().navigationTitle("Receive from Spamcoin (BTC)").navigationBarTitleDisplayMode(.inline)
            .task {
                model.load()
                do { availability = try await LightningBridgeModel.shared.client().availability(direction: .receiveXBT) }
                catch { model.error = error.localizedDescription }
                await model.refresh()
            }
            .onChange(of: unit) { old, new in amount = old.parse(amount).map { new.input($0) } ?? "" }
    }
    @ViewBuilder private func requestCard(_ record: BridgeReceiveRecord) -> some View {
        WalletSection(record.quote == nil ? "Review conversion" : "Receive request") {
            Label(record.implementation.title + " · XBT node", systemImage: "bolt.fill").font(.subheadline)
            LabeledContent("Your node receives", value: unit.display(record.target.msat / 1000)).font(.headline)
            USDValue(sats: record.target.msat / 1000)
            if let quote = record.quote {
                LabeledContent("Sender pays", value: "\(quote.pay_sat.formatted()) BTC sats")
                USDValue(sats: nil, equivalentSats: BridgeDirection.receiveXBT.xbtEquivalentSats(spamcoinSats: Double(quote.pay_sat), rate: quote.rate))
                Text("Spamcoin (BTC) Lightning · sender’s routing fee is additional").font(.caption).foregroundStyle(PaperclipTheme.muted)
                LabeledContent("Bridge fee included", value: String(format: "%.2f%%", quote.spread * 100))
                LabeledContent("Exchange rate", value: String(format: "%.4f XBT / BTC", quote.rate))
                Divider()
                Label(title(record), systemImage: record.received ? "checkmark.circle.fill" : "clock")
                    .foregroundStyle(record.received ? .green : PaperclipTheme.muted)
                if record.received {
                    Text("Your node confirms that the XBT invoice has been paid.").font(.subheadline)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(Double(quote.expires_at) - context.date.timeIntervalSince1970))
                        if remaining > 0 && !record.finished {
                            Text("Invoice expires in \(remaining)s").font(.caption).monospacedDigit()
                            if showingInvoice {
                                ReceiveCode(value: quote.hold_invoice)
                                Text("Share this invoice with a Spamcoin (BTC) Lightning sender. Do not pay it from your XBT wallet.")
                                    .font(.caption).foregroundStyle(PaperclipTheme.muted)
                            } else {
                                Button("Show invoice to share") { showingInvoice = true }.buttonStyle(WalletPrimaryButtonStyle())
                            }
                        } else {
                            Text("This invoice is no longer available to share. An in-flight payment may still be resolving; check your node for receipt.")
                                .font(.caption).foregroundStyle(PaperclipTheme.muted)
                        }
                    }
                    Button("Check receipt") { Task { await model.refresh() } }
                }
                if record.finished { Button("New receive request") { newRequest = true; showingInvoice = false; estimate = nil; amount = "" } }
            } else {
                if let estimate, estimatedHash == record.id {
                    LabeledContent("Estimated sender payment", value: "\(estimate.estimate_sat.formatted()) BTC sats")
                    USDValue(sats: nil, equivalentSats: BridgeDirection.receiveXBT.xbtEquivalentSats(spamcoinSats: Double(estimate.estimate_sat), rate: estimate.rate))
                    Text("Review the final Spamcoin (BTC) amount and fees before sharing the invoice.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    Button("Get Spamcoin (BTC) invoice") {
                        model.perform { try await model.makeQuote(record); showingInvoice = false }
                    }.buttonStyle(WalletPrimaryButtonStyle())
                } else {
                    Button("Check conversion") { check(record) }.buttonStyle(WalletPrimaryButtonStyle())
                }
                Button("Change amount") { newRequest = true; estimate = nil }
            }
        }
    }
    private var history: some View {
        ScrollView {
            VStack(spacing: 20) {
                if model.records.isEmpty { WalletSection { Text("Receive requests will appear here.") } }
                ForEach(model.records.reversed()) { record in
                    WalletSection {
                        Text(unit.display(record.target.msat / 1000)).font(.title2.bold())
                        Text(title(record)).font(.headline)
                        Text(record.created.formatted()).font(.caption).foregroundStyle(PaperclipTheme.muted)
                        Text(record.id).font(.caption.monospaced()).textSelection(.enabled)
                        if record.quote != nil { Button("Check receipt") { Task { await model.refresh(id: record.id) } } }
                    }
                }
            }.walletPageContent()
        }.walletPageBackground().navigationTitle("Bridge receive activity")
    }
    private func title(_ record: BridgeReceiveRecord) -> String {
        if record.received { return "XBT received on your node" }
        if record.quote == nil { return "XBT invoice ready · not shared" }
        if record.nodeState == "ended" { return "Node invoice ended" }
        if record.nodeState == "accepted" { return "Node payment in progress" }
        switch record.bridgeState {
        case "settled": return "Bridge completed · checking node receipt"
        case "funded", "paid", "paying": return "Delivering XBT to your node"
        case "failed", "aborted", "expired": return "Bridge request ended"
        case "lost": return "Request needs attention · check your node"
        default: return "Waiting for Spamcoin (BTC) payment"
        }
    }
    private func create() {
        guard let sats = unit.parse(amount), sats > 0, sats <= 2_100_000_000_000_000 else { return }
        model.perform {
            let info = try await LightningBridgeModel.shared.client().availability(direction: .receiveXBT)
            availability = info
            guard info.open else { throw BridgeError.unavailable("The receive bridge is temporarily unavailable.") }
            if let min = info.min_sat, Double(sats) < min { throw BridgeError.unavailable("Increase the XBT amount to the current bridge minimum.") }
            if let max = info.max_sat, Double(sats) > max { throw BridgeError.unavailable("Reduce the XBT amount to the current bridge maximum.") }
            try await model.create(amount: sats)
            newRequest = false; estimate = nil; showingInvoice = false
            if let record = model.current { try await loadEstimate(record) }
        }
    }
    private func check(_ record: BridgeReceiveRecord) { model.perform { try await loadEstimate(record) } }
    private func loadEstimate(_ record: BridgeReceiveRecord) async throws {
        try record.target.validateTarget(direction: .receiveXBT)
        let result = try await LightningBridgeModel.shared.client().check(record.invoice, direction: .receiveXBT)
        try result.validate(target: record.target)
        self.estimate = result; estimatedHash = record.id
    }
}
