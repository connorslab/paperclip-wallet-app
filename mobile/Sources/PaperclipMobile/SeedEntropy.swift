import Foundation
import CryptoKit
import Security

/// Entropy bytes for BIP39, before its checksum and PBKDF2 seed expansion.
public enum SeedEntropy {
    public static let maximumDiceRolls = 1000

    public enum Failure: Error, LocalizedError {
        case invalidSize, invalidRolls, insufficientRolls, randomUnavailable, invalidSupplement
        public var errorDescription: String? {
            switch self {
            case .invalidSize: return "Choose a 12- or 24-word phrase."
            case .invalidRolls: return "Enter only valid physical dice results for the selected D6, D12, or D20 die."
            case .insufficientRolls: return "Complete all required dice rolls before generating your phrase."
            case .randomUnavailable: return "Secure system randomness is unavailable. No phrase was generated."
            case .invalidSupplement: return "Collect sensor samples before generating your phrase."
            }
        }
    }
    public static func byteCount(words: Int) throws -> Int {
        guard [12, 24].contains(words) else { throw Failure.invalidSize }
        return words == 12 ? 16 : 32
    }
    public static func requiredRolls(words: Int, sides: Int = 6) throws -> Int {
        _ = try byteCount(words: words)
        guard [6, 12, 20].contains(sides) else { throw Failure.invalidRolls }
        return Int(ceil(Double(words == 12 ? 128 : 256) / log2(Double(sides))))
    }
    public static func system(words: Int) throws -> Data {
        let count = try byteCount(words: words)
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.randomUnavailable }
        return bytes
    }
    /// SHA256("Paperclip/dice/v1/sides=N\n" + comma-separated decimal rolls),
    /// Every supplied roll feeds the hash, including rolls beyond the minimum.
    /// The digest is truncated to 16 bytes for 12 words. No RNG is added.
    public static func dice(_ rolls: [Int], sides: Int, words: Int) throws -> Data {
        let count = try byteCount(words: words)
        let required = try requiredRolls(words: words, sides: sides)
        guard rolls.count <= maximumDiceRolls, rolls.allSatisfy({ (1...sides).contains($0) }) else { throw Failure.invalidRolls }
        guard rolls.count >= required else { throw Failure.insufficientRolls }
        let input = "Paperclip/dice/v1/sides=\(sides)\n" + rolls.map(String.init).joined(separator: ",")
        return Data(SHA256.hash(data: Data(input.utf8)).prefix(count))
    }
    /// Fixed-width domain-separated mixing. Sensor input has no credited bit estimate.
    public static func mix(system: Data, sensorDigest: Data, words: Int) throws -> Data {
        let count = try byteCount(words: words)
        guard system.count == count else { throw Failure.invalidSize }
        guard sensorDigest.count == 32 else { throw Failure.invalidSupplement }
        var input = Data("Paperclip/seed-sensors/v1\0".utf8)
        input.append(UInt8(count)); input.append(system); input.append(sensorDigest)
        return Data(SHA256.hash(data: input).prefix(count))
    }
}
