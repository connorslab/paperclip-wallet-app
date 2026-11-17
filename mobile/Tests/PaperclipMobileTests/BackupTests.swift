import XCTest
@testable import PaperclipMobile

final class BackupTests: XCTestCase {
    func testPortableSchemaAndCryptoFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "backup-archive-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let original = try XCTUnwrap(fixture["archive"] as? [String: Any])
        let expected = try JSONDecoder().decode(RecoveryArchive.self, from: JSONSerialization.data(withJSONObject: original))
        let key = try XCTUnwrap(fixture["publicTestKey"] as? String)
        let encrypted = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(fixture["encrypted"] as? String)))
        XCTAssertEqual(try EncryptedBackup.open(encrypted, recoveryKey: key), expected)
        for invalid in try XCTUnwrap(fixture["invalid"] as? [[String: Any]]) {
            var modified = original
            if let replacements = invalid["replace"] as? [String: Any] { modified.merge(replacements) { _, new in new } }
            if let missing = invalid["remove"] as? String { modified.removeValue(forKey: missing) }
            let bytes = try JSONSerialization.data(withJSONObject: modified)
            XCTAssertThrowsError(try JSONDecoder().decode(RecoveryArchive.self, from: bytes), invalid["name"] as? String ?? "fixture")
        }
        // Version 1 writers can omit optional seed words; do not reject old files.
        var old = original; old.removeValue(forKey: "seedPhrase")
        XCTAssertEqual(try JSONDecoder().decode(RecoveryArchive.self, from: JSONSerialization.data(withJSONObject: old)), expected)
    }
    func testExportCannotExceedImportLimit() throws {
        // Preserve the device allocation guard as well as the wire limit.
        let large = RecoveryArchive(network: "xbt-regtest", walletID: "fixture", createdAt: Date(),
            seed: Data(repeating: 7, count: 64), recoveryState: Data(repeating: 0, count: EncryptedBackup.maximumBytes * 3 / 4))
        XCTAssertThrowsError(try EncryptedBackup.seal(large, recoveryKey: EncryptedBackup.generateRecoveryKey())) {
            guard case BackupError.tooLarge = $0 else { return XCTFail("Wrong size failure") }
        }
    }
    func archive() -> RecoveryArchive {
        .init(network: "xbt-regtest", walletID: "test-only", createdAt: Date(timeIntervalSince1970: 123),
              seed: Data(repeating: 7, count: 64), recoveryState: Data("pending rounds and VTXO ancestry fixture".utf8))
    }
    func testFullRecoveryRoundTripAndRandomNonces() throws {
        XCTAssertEqual(archive().version, 2, "Old readers must reject archives containing durable send protection")
        let key = EncryptedBackup.generateRecoveryKey()
        let first = try EncryptedBackup.seal(archive(), recoveryKey: key)
        let second = try EncryptedBackup.seal(archive(), recoveryKey: key)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try EncryptedBackup.open(first, recoveryKey: key), archive())
        XCTAssertNil(first.range(of: Data("pending rounds".utf8)))
    }
    func testWrongKeyTamperingAndTruncationFailClosed() throws {
        let key = EncryptedBackup.generateRecoveryKey()
        let sealed = try EncryptedBackup.seal(archive(), recoveryKey: key)
        XCTAssertThrowsError(try EncryptedBackup.open(sealed, recoveryKey: EncryptedBackup.generateRecoveryKey()))
        var tampered = sealed; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try EncryptedBackup.open(tampered, recoveryKey: key))
        XCTAssertThrowsError(try EncryptedBackup.open(sealed.prefix(20), recoveryKey: key))
        tampered = sealed; tampered[0] ^= 1
        XCTAssertThrowsError(try EncryptedBackup.open(tampered, recoveryKey: key))
    }
    func testSeedOnlyBackupIsRejected() {
        let incomplete = RecoveryArchive(network: "xbt-mainnet", walletID: "test", createdAt: Date(),
            seed: Data(repeating: 0, count: 64), recoveryState: Data())
        XCTAssertThrowsError(try EncryptedBackup.seal(incomplete, recoveryKey: EncryptedBackup.generateRecoveryKey()))
        XCTAssertThrowsError(try EncryptedBackup.open(Data(), recoveryKey: "password"))
    }
}
