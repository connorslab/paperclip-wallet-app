import Foundation

/// The remote node determines Lightning's network, independently of local wallets.
public enum LightningNetwork: Equatable {
    case mainnet, regtest

    public static func decode(_ info: [String: Any], implementation: LightningImplementation) throws -> Self {
        if implementation == .cln {
            switch info["network"] as? String {
            case "bitcoin": return .mainnet
            case "regtest": return .regtest
            default: break
            }
        } else {
            let chains = info["chains"] as? [[String: String]] ?? []
            if chains.count == 1, let chain = chains.first, chain["chain"] == "bitcoin" {
                switch chain["network"] {
                case "mainnet": return .mainnet
                case "regtest": return .regtest
                default: break
                }
            }
        }
        throw ConnectionFieldError(field: "Node network", reason: "Connect an XBT mainnet or regtest node.")
    }
}
