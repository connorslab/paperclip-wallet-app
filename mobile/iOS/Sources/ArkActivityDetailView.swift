import SwiftUI
import PaperclipMobile

struct ArkActivityDetailView: View {
	@EnvironmentObject private var store: WalletStore
	@AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
	let item: ActivityItem
	private var current: ActivityItem { store.activity.first { $0.id == item.id } ?? item }

	var body: some View {
		ScrollView {
			VStack(spacing: 22) {
				WalletAmountHero(amount: unit.signed(current.amountSat), caption: "Balance change", detail: "Ark activity",
					symbol: current.amountSat > 0 ? "arrow.down.left" : current.amountSat < 0 ? "arrow.up.right" : "arrow.left.arrow.right").privacySensitive()
				WalletSection("Payment details") {
					WalletReviewDetail(title: "Status", value: current.status, emphasized: true)
					if let date = current.date {
						Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(PaperclipTheme.muted)
					}
					Text("Status reflects the last wallet update.").font(.caption).foregroundStyle(PaperclipTheme.muted)
				}
				WalletSection("Record details") {
					WalletReviewDetail(title: "Type", value: current.title)
					Text(current.detail).font(.caption.monospaced()).textSelection(.enabled)
				}
				WalletSection("Need to check the outcome?") {
					Text("Pending or submitted does not mean the recipient has been paid. Refresh Activity before trying again.")
					Text("An Ark deposit needs on-chain confirmations and server registration before it becomes available.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
					NavigationLink { WalletSupportView() } label: {
						WalletNavigationRow("Payment help", subtitle: "Pending payments, deposits, and recovery", icon: "questionmark.circle")
					}.buttonStyle(.plain)
				}
			}.walletPageContent()
		}.walletPageBackground().navigationTitle(current.title).navigationBarTitleDisplayMode(.inline)
			.toolbar {
				Button("Refresh", systemImage: "arrow.clockwise") { store.run { try await store.refreshActivity() } }.disabled(store.busy)
			}
	}
}
