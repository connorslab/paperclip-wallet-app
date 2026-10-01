import Foundation
import CryptoKit

public enum BackupError: Error { case invalidKey, unsupportedFormat, invalidArchive, tooLarge }

/// A consistent native-engine export, not a copy of a live SQLite main file.
/// recoveryState must include database/WAL state, VTXO ancestry, and pending actions.
public struct RecoveryArchive: Codable, Sendable, Equatable {
    public let version: Int
    public let network: String
    public let walletID: String
    public let createdAt: Date
    public let seed: Data
    public let recoveryState: Data
    public init(network: String, walletID: String, createdAt: Date, seed: Data, recoveryState: Data) {
        self.version = 1; self.network = network; self.walletID = walletID
        self.createdAt = createdAt; self.seed = seed; self.recoveryState = recoveryState
    }
    public func validate() throws {
        guard version == 1, ["xbt-mainnet", "xbt-regtest"].contains(network),
              !walletID.isEmpty, walletID.count <= 128, seed.count == 64, !recoveryState.isEmpty else {
            throw BackupError.invalidArchive
        }
    }
}

public enum EncryptedBackup {
    private static let header = Data("PAPERCLIP-BACKUP-1\n".utf8)
    public static let maximumBytes = 64 * 1024 * 1024
    public static func generateRecoveryKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }
    private static func key(_ text: String) throws -> SymmetricKey {
        guard text.count <= 64, let bytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              bytes.count == 32 else { throw BackupError.invalidKey }
        return SymmetricKey(data: bytes)
    }
    public static func seal(_ archive: RecoveryArchive, recoveryKey: String) throws -> Data {
        try archive.validate()
        guard archive.recoveryState.count < maximumBytes / 2 else { throw BackupError.tooLarge }
        let plain = try JSONEncoder().encode(archive)
        let sealed = try AES.GCM.seal(plain, using: key(recoveryKey), authenticating: header)
        guard let combined = sealed.combined else { throw BackupError.invalidArchive }
        return header + combined
    }
    public static func open(_ data: Data, recoveryKey: String) throws -> RecoveryArchive {
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        guard data.starts(with: header) else { throw BackupError.unsupportedFormat }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(header.count))
        let plain = try AES.GCM.open(box, using: key(recoveryKey), authenticating: header)
        let archive = try JSONDecoder().decode(RecoveryArchive.self, from: plain)
        try archive.validate()
        return archive
    }
}

public protocol WalletBackupEngine: Sendable {
    // Serialize with wallet mutations. Export a consistent, complete recovery snapshot.
    func exportRecoveryArchive() async throws -> RecoveryArchive
    // Validate engine schema/network/key ownership, stage in a new protected directory,
    // and atomically commit. Refuse to replace an existing wallet. Reconcile before spending.
    func restoreIntoEmptyWallet(_ archive: RecoveryArchive) async throws
}
