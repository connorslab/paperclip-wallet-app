import Foundation
import CryptoKit

/// Descriptive checks on unconditioned sensor bytes, NOT a validated entropy estimate.
/// Correlated, deterministic data can pass these checks. Never credit these values
/// as cryptographic bits or apply them to the SHA256 output (which hides defects).
public struct SensorSampleHealth: Sendable {
    public private(set) var packets = 0
    public private(set) var bytes = 0
    public private(set) var repeatedPackets = 0
    public private(set) var longestByteRun = 0
    private var histogram = [Int](repeating: 0, count: 256)
    private var previousDigest: Data?
    private var consecutiveRepeats = 0
    private var previousByte: UInt8?
    private var run = 0
    public init() {}
    public var distinctValues: Int { histogram.filter { $0 > 0 }.count }
    public var mostCommonFraction: Double { bytes == 0 ? 0 : Double(histogram.max() ?? 0) / Double(bytes) }
    /// Empirical marginal min-entropy, without an independence assumption or confidence bound.
    /// It describes only the observed histogram, not unpredictability to an attacker.
    public var empiricalMinEntropy: Double { bytes == 0 ? 0 : -log2(mostCommonFraction) }
    public var looksStuck: Bool { bytes > 0 && (distinctValues <= 1 || (consecutiveRepeats >= 2)) }
    public var status: String {
        if packets == 0 { return "No samples" }
        if looksStuck { return "Repetitive input detected" }
        if packets < 3 || bytes < 256 { return "Insufficient samples for diagnostics" }
        return "Variation observed · entropy not validated"
    }
    public mutating func observe(_ data: Data) {
        guard !data.isEmpty else { return }
        let digest = Data(SHA256.hash(data: data))
        if digest == previousDigest { repeatedPackets += 1; consecutiveRepeats += 1 }
        else { consecutiveRepeats = 0 }
        previousDigest = digest; packets += 1
        // Bound the diagnostic work per packet; hashing above still covers the
        // entire raw packet. Include multiple pixel channels, not just alpha.
        if data.count <= 4096 {
            for byte in data { observeByte(byte) }
        } else {
            for block in 0..<256 {
                let offset = block * (data.count - 16) / 255
                for index in offset..<(offset + 16) { observeByte(data[data.startIndex + index]) }
            }
        }
    }
    private mutating func observeByte(_ byte: UInt8) {
        histogram[Int(byte)] += 1; bytes += 1
        run = byte == previousByte ? run + 1 : 1
        longestByteRun = max(longestByteRun, run); previousByte = byte
    }
}
