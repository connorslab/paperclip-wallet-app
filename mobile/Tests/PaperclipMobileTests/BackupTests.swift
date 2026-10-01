import XCTest
@testable import PaperclipMobile

final class BackupTests: XCTestCase {
    func archive() -> RecoveryArchive {
        .init(network: "xbt-regtest", walletID: "test-only", createdAt: Date(timeIntervalSince1970: 123),
              seed: Data(repeating: 7, count: 64), recoveryState: Data("pending rounds and VTXO ancestry fixture".utf8))
    }
    func testFullRecoveryRoundTripAndRandomNonces() throws {
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
