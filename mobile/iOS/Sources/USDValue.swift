import SwiftUI

@MainActor final class XBTPrice: ObservableObject {
    static let shared = XBTPrice()
    @Published private(set) var usd: Double?
    @Published private(set) var updated: Date?
    private var attempt: Date?
    private var loading = false
    private struct Quote: Decodable { let price: Double; let updated: Double }
    func refresh() async {
        guard !loading, attempt.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        loading = true; attempt = Date()
        defer { loading = false }
        do {
            var request = URLRequest(url: URL(string: "https://xbt.live/api/widget")!)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            // Fetch only the public quote. No wallet identifiers or amounts are sent.
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let quote = try JSONDecoder().decode(Quote.self, from: data)
            let time = Date(timeIntervalSince1970: quote.updated / 1000)
            guard quote.price.isFinite, quote.price > 0, quote.updated.isFinite,
                  time <= Date().addingTimeInterval(300), Date().timeIntervalSince(time) < 86400 else { return }
            usd = quote.price; updated = time
        } catch { /* Retain the last quote; its age remains visible. */ }
    }
}

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
                else if let sats, let usd = price.usd, let updated = price.updated {
                    let stale = now.timeIntervalSince(updated) > 900
                    Text("≈ " + (Double(sats) / 100_000_000 * usd).formatted(.currency(code: "USD")) + " USD" + (stale ? " · stale rate" : ""))
                        .accessibilityLabel("Approximate US dollar value " + (Double(sats) / 100_000_000 * usd).formatted(.currency(code: "USD")) + (stale ? ", stale exchange rate" : ""))
                } else { Text("USD value unavailable") }
            }
        }.font(.caption).foregroundStyle(PaperclipTheme.muted).privacySensitive()
            .help("Estimate from xbt.live. Exchange value may differ from the amount available when trading.")
            .task(id: scene) {
                guard mainnet, scene == .active else { return }
                while !Task.isCancelled {
                    await price.refresh()
                    now = Date()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
    }
}
