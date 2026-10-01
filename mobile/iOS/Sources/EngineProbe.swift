import Foundation
import Security

enum EngineProbe {
    static func run() -> String {
        var seed = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed) == errSecSuccess else {
            return "Secure randomness unavailable."
        }
        defer { seed.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var fingerprint = [UInt8](repeating: 0, count: 4)
        guard paperclip_mobile_probe(&seed, &fingerprint) == 0 else { return "Native engine check failed." }
        return "Rust wallet engine linked. Ephemeral regtest key derivation passed. No wallet was created."
    }
}
