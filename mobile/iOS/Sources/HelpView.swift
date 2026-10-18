import SwiftUI
import UIKit

enum WalletHelp {
    static let privacy = URL(string: "https://github.com/connorslab/paperclip-wallet-app/blob/feature/ios-wallet/mobile/docs/privacy.md")!
    static let support = URL(string: "https://github.com/connorslab/paperclip-wallet-app/blob/feature/ios-wallet/mobile/docs/support.md")!
    static let email = "contact@paperclippool.xyz"
    static let emailURL = URL(string: "mailto:contact@paperclippool.xyz?subject=Paperclip%20Wallet%20Support")!
}

struct WalletSupportView: View {
    @State private var copied = false
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletSection {
                    WalletBrand()
                    Text("We’re here to help.").font(.title2.bold())
                    Text("Questions about your wallet? Contact Paperclip Holdings LLC. Support does not require a donation.").foregroundStyle(PaperclipTheme.muted)
                }
                WalletSection("Contact support") {
                    Link(destination: WalletHelp.emailURL) {
                        WalletNavigationRow("Email Paperclip", subtitle: WalletHelp.email, icon: "envelope")
                    }
                    Button(copied ? "Email address copied" : "Copy email address") {
                        UIPasteboard.general.string = WalletHelp.email; copied = true
                    }
                    Link(destination: WalletHelp.support) {
                        WalletNavigationRow("Wallet help", subtitle: "Connections, payments, and recovery", icon: "questionmark.circle")
                    }
                }
                WalletSection("Before you send") {
                    Text("Include your app version, iOS version, and what happened. Hide private details in screenshots.")
                    Text("Never share seed words, private keys, backup recovery keys, or node credentials. We will never ask for them.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))").font(.caption)
                }
                WalletSection {
                    Link("Privacy policy", destination: WalletHelp.privacy)
                }
            }.walletPageContent()
        }.walletPageBackground().navigationTitle("Contact support").navigationBarTitleDisplayMode(.inline)
    }
}
