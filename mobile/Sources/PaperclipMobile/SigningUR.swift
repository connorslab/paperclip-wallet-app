import Foundation
import URKit

// Validate all lengths before handing untrusted fountain headers to URKit.
// In particular its Part initializer converts UInt64 fields to narrower integers.
final class SigningURCollector {
    private let decoder = URDecoder()
    private var identity: String?
    private var seen = Set<String>()
    var total = 0
    var received: Int { decoder.receivedFragmentIndexes.count }

    func accept(_ frame: String) throws -> Data? {
        let fields = frame.lowercased().split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3, fields[0] == "ur:crypto-psbt" else { throw SigningQRError.unsupported }
        if fields.count == 3 {
            let raw = try Bytewords.decode(String(fields[2]), style: .minimal)
            guard case let .array(values) = try CBOR(raw), values.count == 5,
                  case let .unsigned(seq) = values[0], seq > 0, seq <= UInt32.max,
                  case let .unsigned(count) = values[1], count > 0, count <= 1295,
                  case let .unsigned(length) = values[2], length > 0, length <= SigningQR.maximumBytes + 8,
                  case let .unsigned(checksum) = values[3], checksum <= UInt32.max,
                  case let .bytes(data) = values[4], !data.isEmpty, data.count <= 2048,
                  UInt64(data.count) * (count - 1) < length, length <= UInt64(data.count) * count,
                  fields[1] == "\(seq)-\(count)" else { throw SigningQRError.invalid }
            let key = "\(count):\(length):\(checksum):\(data.count)"
            if let identity, identity != key { throw SigningQRError.mixed }
            identity = key; total = Int(count)
        } else {
            guard identity == nil else { throw SigningQRError.mixed }
            total = 1
        }
        // Bound fountain work and retained mixed fragments, including adversarial streams.
        guard seen.count < 4096 || seen.contains(frame.lowercased()) else { throw SigningQRError.tooLarge }
        if !seen.insert(frame.lowercased()).inserted { return nil }
        guard decoder.receivePart(frame) else { throw SigningQRError.invalid }
        guard let result = decoder.result else { return nil }
        let ur = try result.get()
        guard case let .bytes(payload) = ur.cbor, !payload.isEmpty, payload.count <= SigningQR.maximumBytes else { throw SigningQRError.invalid }
        return Data(payload)
    }
}
