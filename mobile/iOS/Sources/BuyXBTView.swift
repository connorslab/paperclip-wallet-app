import SwiftUI

struct BuyXBTView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletSection {
                    WalletBrand()
                    Text("Find your next XBT.").font(.title2.bold())
                    Text("This list includes only exchanges selected for non-KYC trading. Buy XBT, then withdraw to your Paperclip on-chain receive address.")
                        .foregroundStyle(PaperclipTheme.muted)
                }
                WalletSection("Non-KYC exchanges") {
                    exchange("SafeTrade", market: "XBT / USDT", domain: "safetrade.com",
                             url: "https://safetrade.com/exchange/XBT-USDT?type=pro")
                    Divider()
                    exchange("NeoxEx", market: "XBT / USDC", domain: "neoxa.exchange",
                             url: "https://neoxa.exchange/trade/BTCB2_USDC")
                    Divider()
                    exchange("NeoxEx", market: "XBT / BTC", domain: "neoxa.exchange",
                             url: "https://neoxa.exchange/trade/BTCB2_BTC")
                }
                WalletSection {
                    Link("Create a NeoxEx account · Referral link", destination: URL(string: "https://neoxa.exchange/register?ref=NEXE5E25284")!)
                    Text("New to NeoxEx? Use our referral sign-up link to support Paperclip. The market buttons above open each trading pair directly.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                WalletSection("Bring it home") {
                    Text("Choose the Bitcoin BLAKE2b (XBT) network when withdrawing. NeoxEx also uses BTCB2 in its market links.")
                    Text("Exchange links open in your browser. Check each exchange’s current verification rules, availability, fees, and withdrawal requirements before depositing. Paperclip does not handle your purchase.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
            }.walletPageContent()
        }.walletPageBackground().navigationTitle("Buy XBT").navigationBarTitleDisplayMode(.inline)
    }

    private func exchange(_ name: String, market: String, domain: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 14) {
                Image(systemName: "building.columns").font(.title3).foregroundStyle(PaperclipTheme.orange)
                    .frame(width: 40, height: 40)
                    .background(PaperclipTheme.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline).foregroundStyle(.primary)
                    Text(market).font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    Text(domain).font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").foregroundStyle(PaperclipTheme.orange)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("Open \(name) in your browser")
    }
}
