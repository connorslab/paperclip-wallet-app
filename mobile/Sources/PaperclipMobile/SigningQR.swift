import Foundation
import zlib

public enum SigningQRError: LocalizedError {
    case invalid, mixed, tooLarge, unsupported
    public var errorDescription: String? { switch self {
    case .invalid: "Invalid signing QR. Reset the scan and try again."
    case .mixed: "These frames belong to different QR requests. Reset the scan and show only one request."
    case .tooLarge: "This QR transfer is too large."
    case .unsupported: "Scan a signed PSBT QR, or export the public account key as a plain QR (Specter on SeedSigner)."
    } }
}

public enum SigningQR {
    public static let maximumBytes = 160 * 1024
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
    public static func frames(_ data: Data, type: Character = "P") throws -> [String] {
        guard !data.isEmpty, data.count <= maximumBytes else { throw SigningQRError.tooLarge }
        let encoded = Array(base32(data).utf8), chunk = 240
        let total = (encoded.count + chunk - 1) / chunk
        guard total <= 1295 else { throw SigningQRError.tooLarge }
        func number(_ value: Int) -> String { let s = String(value, radix: 36).uppercased(); return s.count == 1 ? "0" + s : s }
        return (0..<total).map { index in
            "B$2\(type)\(number(total))\(number(index))" + String(decoding: encoded[(index * chunk)..<min((index + 1) * chunk, encoded.count)], as: UTF8.self)
        }
    }
    public static func base32(_ data: Data) -> String {
        var buffer: UInt32 = 0, bits = 0, output = [UInt8]()
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte); bits += 8
            while bits >= 5 { bits -= 5; output.append(alphabet[Int((buffer >> bits) & 31)]) }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { output.append(alphabet[Int((buffer << (5 - bits)) & 31)]) }
        return String(decoding: output, as: UTF8.self)
    }
    static func decode32(_ text: String) throws -> Data {
        var buffer: UInt32 = 0, bits = 0, data = Data()
        guard [0, 2, 4, 5, 7].contains(text.utf8.count % 8) else { throw SigningQRError.invalid }
        for byte in text.utf8 {
            guard let value = alphabet.firstIndex(of: byte) else { throw SigningQRError.invalid }
            buffer = (buffer << 5) | UInt32(value); bits += 5
            if bits >= 8 { bits -= 8; data.append(UInt8((buffer >> bits) & 255)) }
            buffer &= (1 << bits) - 1
        }
        guard buffer == 0 else { throw SigningQRError.invalid }
        return data
    }
    static func inflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw SigningQRError.invalid }
        defer { inflateEnd(&stream) }
        var output = Data(count: maximumBytes + 1)
        let result = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(out.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard stream.total_out <= maximumBytes else { throw SigningQRError.tooLarge }
        guard result == Z_STREAM_END, stream.avail_in == 0 else { throw SigningQRError.invalid }
        return output.prefix(Int(stream.total_out))
    }
    public static func binary(_ value: String) throws -> Data {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= maximumBytes * 2 else { throw SigningQRError.tooLarge }
        if value.lowercased().hasPrefix("ur:") { throw SigningQRError.unsupported }
        if value.count % 2 == 0, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            let bytes = Array(value.utf8)
            return Data(try stride(from: 0, to: bytes.count, by: 2).map { index in
                guard let byte = UInt8(String(decoding: bytes[index..<index+2], as: UTF8.self), radix: 16) else { throw SigningQRError.invalid }; return byte
            })
        }
        guard let data = Data(base64Encoded: value), !data.isEmpty, data.count <= maximumBytes else { throw SigningQRError.invalid }
        return data
    }
}

public struct SigningQRCollector {
    private var identity: String?
    private var ur: SigningURCollector?
    private var parts: [Int: String] = [:]
    private var size = 0
    public private(set) var total = 0
    public var received: Int { ur?.received ?? parts.count }
    public init() {}
    // The caller decides whether the completed bytes are a public wallet, PSBT, or transaction.
    public mutating func accept(_ frame: String, publicWallet: Bool = false) throws -> Data? {
        guard frame.utf8.count <= 4096 else { throw SigningQRError.tooLarge }
        if frame.lowercased().hasPrefix("ur:") {
            guard !publicWallet else { throw SigningQRError.unsupported }
            guard identity == nil else { throw SigningQRError.mixed }
            if ur == nil { ur = SigningURCollector() }
            let result = try ur!.accept(frame)
            total = ur!.total
            return result
        }
        guard ur == nil else { throw SigningQRError.mixed }
        let bytes = Array(frame.utf8)
        if frame.hasPrefix("B$") {
            guard bytes.count > 8, [72, 50, 90].contains(bytes[2]), (publicWallet ? [85, 74] : [80, 84]).contains(Int(bytes[3])),
                  let count = Int(String(decoding: bytes[4..<6], as: UTF8.self), radix: 36), count > 0, count <= 1295,
                  let index = Int(String(decoding: bytes[6..<8], as: UTF8.self), radix: 36), index >= 0, index < count else { throw SigningQRError.invalid }
            let header = String(decoding: bytes[0..<6], as: UTF8.self)
            let body = String(decoding: bytes[8...], as: UTF8.self)
            try insert(body, index: index, count: count, header: header)
            guard parts.count == total else { return nil }
            var data = Data()
            for index in 0..<total {
                let part = parts[index]!
                if bytes[2] == 72 {
                    guard part.count % 2 == 0, part.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { throw SigningQRError.invalid }
                }
                data.append(try bytes[2] == 72 ? SigningQR.binary(part) : SigningQR.decode32(part))
            }
            if bytes[2] == 90 { data = try SigningQR.inflate(data) }
            guard data.count <= SigningQR.maximumBytes else { throw SigningQRError.tooLarge }
            return data
        }
        let fields = frame.split(separator: " ", maxSplits: 1)
        if fields.count == 2, fields[0].hasPrefix("p"), let range = fields[0].range(of: "of"),
           let index = Int(fields[0][fields[0].index(after: fields[0].startIndex)..<range.lowerBound]),
           let count = Int(fields[0][range.upperBound...]), count > 0, count <= 1295, index > 0, index <= count {
            try insert(String(fields[1]), index: index - 1, count: count, header: "p\(count)")
            guard parts.count == total else { return nil }
            let text = (0..<total).map { parts[$0]! }.joined()
            return publicWallet ? Data(text.utf8) : try SigningQR.binary(text)
        }
        guard identity == nil else { throw SigningQRError.mixed }
        return publicWallet ? Data(frame.utf8) : try SigningQR.binary(frame)
    }
    private mutating func insert(_ part: String, index: Int, count: Int, header: String) throws {
        if let identity, identity != header || total != count { throw SigningQRError.mixed }
        if let existing = parts[index] { guard existing == part else { throw SigningQRError.mixed }; return }
        guard size + part.utf8.count <= SigningQR.maximumBytes * 2 else { throw SigningQRError.tooLarge }
        identity = header; total = count; parts[index] = part; size += part.utf8.count
    }
}
