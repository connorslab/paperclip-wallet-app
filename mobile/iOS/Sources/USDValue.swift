import SwiftUI
import PaperclipMobile

struct USDValue: View {
    let sats: UInt64?
    var hidden = false
    var mainnet = true
    @ObservedObject private var price = XBTPrice.shared
    @Environment(\.scenePhase) private var scene
    @State private var now = Date()
    var body: some View {
        Group {
            if mainnet {
                if hidden { Text("•••• USD") }
                else if let sats, let usd = price.usd, let updated = price.updated, now.timeIntervalSince(updated) < 86400 {
                    let stale = now.timeIntervalSince(updated) > 900
                    Text("≈ " + (Double(sats) / 100_000_000 * usd).formatted(.currency(code: "USD")) + " USD" + (stale ? " · stale rate" : ""))
                        .accessibilityLabel("Approximate US dollar value " + (Double(sats) / 100_000_000 * usd).formatted(.currency(code: "USD")) + (stale ? ", stale exchange rate" : ""))
                } else if sats == nil {
                    Text("USD estimate pending balance")
                } else {
                    Button {
                        Task { await price.refresh(force: true); now = Date() }
                    } label: {
                        Label(price.loading ? "Updating USD value…" : "USD unavailable · retry", systemImage: price.loading ? "clock" : "arrow.clockwise")
                    }.buttonStyle(.plain).disabled(price.loading)
                }
            }
        }.font(.caption).foregroundStyle(PaperclipTheme.muted).privacySensitive()
            .help("Estimate from xbt.live. Exchange value may differ from the amount available when trading.")
            .task(id: scene) {
                guard mainnet, scene == .active else { return }
                while !Task.isCancelled {
                    await price.refresh()
                    now = Date()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }
}
