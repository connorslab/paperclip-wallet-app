import Foundation

public enum WalletKind: String, Codable, CaseIterable, Sendable {
    case hot, hardware, watch
    public var title: String { switch self { case .hot: "Mobile wallet"; case .hardware: "QR hardware wallet"; case .watch: "Watch-only wallet" } }
    public var icon: String { switch self { case .hot: "wallet.pass"; case .hardware: "qrcode"; case .watch: "eye" } }
}

public struct WalletProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public let kind: WalletKind
    public let network: String
    public let descriptor: String?
    public init(id: String = UUID().uuidString, name: String, kind: WalletKind, network: String, descriptor: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.network = network; self.descriptor = descriptor
    }
    public var keyAccount: String { id == "legacy" ? "wallet-key-v2" : "wallet-key-v3-" + id }
    public var connectionAccount: String { id == "legacy" ? "wallet-connection-v2" : "wallet-connection-v3-" + id }
    public var supportsArk: Bool { kind == .hot }
}

public struct WalletCatalog: Codable, Sendable {
    public var wallets: [WalletProfile]
    public var selectedID: String?
    public init(wallets: [WalletProfile] = [], selectedID: String? = nil) { self.wallets = wallets; self.selectedID = selectedID }
    public var selected: WalletProfile? { wallets.first { $0.id == selectedID } }
    public mutating func add(_ profile: WalletProfile) throws {
        guard !wallets.contains(where: { $0.id == profile.id }), !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WalletCatalogError.invalidProfile
        }
        wallets.append(profile); selectedID = profile.id
    }
}
public enum WalletCatalogError: Error { case invalidProfile }
