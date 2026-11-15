import SwiftUI
import PaperclipMobile

struct PaymentReceiptView: View {
    let receipt: PaymentReceipt
    let amount: UInt64?
    let mainnet: Bool
    let done: () -> Void
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @State private var copied = false
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if receipt.completed {
                    PaymentCelebration().accessibilityIdentifier("verified-payment-celebration")
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 52)).foregroundStyle(PaperclipTheme.orange).padding(.top, 24)
                        .accessibilityHidden(true)
                }
                Text(receipt.title).font(.title.bold()).multilineTextAlignment(.center)
                Text(receipt.message).font(.subheadline).foregroundStyle(PaperclipTheme.muted).multilineTextAlignment(.center)
                WalletSection("Details") {
                    if let amount { LabeledContent("Amount", value: unit.display(amount)) }
                    if let txid = receipt.transactionID {
                        Text("Transaction ID").font(.caption).foregroundStyle(PaperclipTheme.muted)
                        Text(String(txid.prefix(12)) + "…" + String(txid.suffix(12))).font(.body.monospaced()).accessibilityLabel(txid)
                        Button(copied ? "Transaction ID copied" : "Copy transaction ID", systemImage: "doc.on.doc") {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: txid]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                            copied = true
                        }
                        if mainnet, txid.count == 64, txid.allSatisfy({ $0.isHexDigit }), let url = URL(string: "https://mempool.guide/tx/" + txid) {
                            Link("View transaction", destination: url)
                        }
                    }
                }
                Button("Done", action: done).buttonStyle(WalletPrimaryButtonStyle())
            }.walletPageContent()
        }.walletPageBackground().navigationTitle("Payment status").navigationBarTitleDisplayMode(.inline)
    }
}
