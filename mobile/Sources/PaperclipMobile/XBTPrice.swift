import Foundation
import Combine

/// Public market data only: requests never contain wallet information.
@MainActor public final class XBTPrice: ObservableObject {
    public static let shared = XBTPrice()
    @Published public private(set) var usd: Double?
    @Published public private(set) var updated: Date?
    @Published public private(set) var loading = false
    private var nextAttempt = Date.distantPast
    private var requestTask: Task<Void, Never>?
    private let fetch: () async throws -> Data
    private let clock: () -> Date
    private let defaults: UserDefaults
    private static let cacheKey = "paperclip.publicXBTQuote.v1"
    private struct Quote: Decodable { let price: Double; let updated: Double }

    public convenience init() {
        self.init(defaults: .standard, clock: Date.init) {
            var request = URLRequest(url: URL(string: "https://xbt.live/api/widget")!)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    init(defaults: UserDefaults, clock: @escaping () -> Date, fetch: @escaping () async throws -> Data) {
        self.defaults = defaults; self.clock = clock; self.fetch = fetch
        if let data = defaults.data(forKey: Self.cacheKey) { _ = accept(data) }
    }

    @discardableResult private func accept(_ data: Data) -> Bool {
        guard let quote = try? JSONDecoder().decode(Quote.self, from: data),
              quote.price.isFinite, quote.price > 0, quote.updated.isFinite else { return false }
        let time = Date(timeIntervalSince1970: quote.updated / 1000)
        guard time <= clock().addingTimeInterval(300), clock().timeIntervalSince(time) < 86400 else { return false }
        usd = quote.price; updated = time
        return true
    }

    public func refresh(force: Bool = false) async {
        if let requestTask { await requestTask.value; return }
        guard force || clock() >= nextAttempt else { return }
        loading = true
        // A card disappearing must not cancel the shared quote request for every wallet.
        let task = Task { @MainActor in
            defer { loading = false; requestTask = nil }
            do {
                let data = try await fetch()
                guard accept(data) else { throw URLError(.cannotParseResponse) }
                defaults.set(data, forKey: Self.cacheKey)
                nextAttempt = clock().addingTimeInterval(300)
            } catch {
                nextAttempt = clock().addingTimeInterval(30)
            }
        }
        requestTask = task
        await task.value
    }
}
