import XCTest
import URKit
@testable import PaperclipMobile

final class SigningQRTests: XCTestCase {
    func testSeedSignerAnimatedReturns() throws {
        let url = Bundle.module.url(forResource: "seedsigner", withExtension: "json", subdirectory: "Fixtures")!
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        for fixture in fixtures {
            let signed = Data(base64Encoded: fixture["signed"] as! String)!
            let frames = fixture["ur"] as! [String]
            var collector = SigningQRCollector()
            var result: Data?
            // The signer cycles; starting in the middle must work too.
            for frame in frames.reversed() {
                if let data = try collector.accept(frame.uppercased()) { result = data; break }
            }
            XCTAssertEqual(result, signed, fixture["script"] as! String)
        }
    }
    func testBBQrAndSpecterMultipart() throws {
        let payload = Data((0..<2048).map { UInt8($0 % 251) })
        let frames = try SigningQR.frames(payload)
        var collector = SigningQRCollector()
        XCTAssertNil(try collector.accept(frames.last!))
        XCTAssertNil(try collector.accept(frames.last!))
        var result: Data?
        for frame in frames.dropLast().reversed() { result = try collector.accept(frame) }
        XCTAssertEqual(result, payload)
        var specter = SigningQRCollector()
        let text = payload.base64EncodedString(), middle = text.index(text.startIndex, offsetBy: text.count / 2)
        XCTAssertNil(try specter.accept("p2of2 " + text[middle...]))
        XCTAssertEqual(try specter.accept("p1of2 " + text[..<middle]), payload)
    }
    func testCompressedBBQr() throws {
        var collector = SigningQRCollector()
        let payload = Data([0x70, 0x73, 0x62, 0x74, 0xff]) + Data(String(repeating: "paperclip", count: 100).utf8)
        XCTAssertEqual(try collector.accept("B$ZP0100FMUE4KXZL6IFREC2SSOJGWJQZIMGLDBSA2CACAA"), payload)
    }
    func testRejectsMixedMalformedAndOversizedFrames() throws {
        var collector = SigningQRCollector()
        XCTAssertNil(try collector.accept("B$2P0200MFRGGZDF"))
        XCTAssertThrowsError(try collector.accept("B$2P0301MFRGGZDF"))
        XCTAssertThrowsError(try collector.accept("B$2P0200NFRGGZDF"))
        var malformed = SigningQRCollector()
        XCTAssertThrowsError(try malformed.accept("B$HP0100zz"))
        XCTAssertThrowsError(try malformed.accept(String(repeating: "A", count: 4097)))
        // Guard UInt64-to-UInt32 conversion in the upstream fountain decoder.
        let dangerous = CBOR.array([.unsigned(UInt64.max), .unsigned(2), .unsigned(20), .unsigned(0), .bytes(Data(repeating: 0, count: 10))])
        let body = Bytewords.encode(dangerous.cborData, style: .minimal)
        var ur = SigningQRCollector()
        XCTAssertThrowsError(try ur.accept("ur:crypto-psbt/1-2/" + body))
    }
    func testSinglePartURAndPublicKeyExport() throws {
        let payload = Data([0x70, 0x73, 0x62, 0x74, 0xff])
        let ur = try UR(type: "crypto-psbt", cbor: .bytes(payload))
        var collector = SigningQRCollector()
        XCTAssertEqual(try collector.accept(ur.qrString), payload)
        var publicKey = SigningQRCollector()
        let key = "[deadbeef/84h/0h/0h]xpubExample"
        XCTAssertEqual(try publicKey.accept(key, publicWallet: true), Data(key.utf8))
    }
    func testCatalogKeepsLegacyAccountsAndIsolatesNewWallets() throws {
        var catalog = WalletCatalog()
        let legacy = WalletProfile(id: "legacy", name: "Existing", kind: .hot, network: "xbt-mainnet")
        let hardware = WalletProfile(name: "Signer", kind: .hardware, network: "xbt-mainnet", descriptor: "public descriptor")
        try catalog.add(legacy); try catalog.add(hardware)
        XCTAssertEqual(catalog.selected, hardware)
        XCTAssertEqual(legacy.keyAccount, "wallet-key-v2")
        XCTAssertEqual(legacy.connectionAccount, "wallet-connection-v2")
        XCTAssertNotEqual(legacy.keyAccount, hardware.keyAccount)
        XCTAssertNotEqual(legacy.connectionAccount, hardware.connectionAccount)
        XCTAssertFalse(hardware.supportsArk)
        let restored = try JSONDecoder().decode(WalletCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(restored.wallets, catalog.wallets)
        XCTAssertEqual(restored.selected, hardware)
        XCTAssertThrowsError(try catalog.add(hardware))
    }
}
