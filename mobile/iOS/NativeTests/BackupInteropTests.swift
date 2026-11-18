import XCTest
import PaperclipMobile

/// Public synthetic regtest archives only, in the isolated native test host.
final class BackupInteropTests: XCTestCase {
    func testArchiveInstallationPreservesExistingProfileAndRejectsDuplicate() async throws {
        let bundle = Bundle(for: Self.self)
        let fixtureURL = try XCTUnwrap(bundle.url(forResource: "native-v2-regtest.json", withExtension: nil, subdirectory: "NativeBackupFixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let key = try XCTUnwrap(fixture["publicRecoveryKey"] as? String)
        let archiveURL = try XCTUnwrap(bundle.url(forResource: "android-v2-regtest.pcbackup", withExtension: nil, subdirectory: "NativeBackupFixtures"))
        let archive = try EncryptedBackup.open(Data(contentsOf: archiveURL), recoveryKey: key)
        let wallet = NativeWallet()
        let savedCatalog = try WalletKeychain.read("wallet-catalog-v1")
        let original = WalletProfile(name: "Restore isolation fixture", kind: .hot, network: "xbt-regtest")
        var created = [original]
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperclipWallets")
        defer {
            "{\"op\":\"close\"}".withCString { request in
                archive.seed.withUnsafeBytes { bytes in
                    if let reply = paperclip_mobile_call(request, bytes.bindMemory(to: UInt8.self).baseAddress) { paperclip_mobile_free(reply) }
                }
            }
            if let savedCatalog { try? WalletKeychain.save(savedCatalog, account: "wallet-catalog-v1") }
            else { try? WalletKeychain.delete("wallet-catalog-v1") }
            for profile in created {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(profile.id))
                try? WalletKeychain.delete(profile.keyAccount)
                try? WalletKeychain.delete(profile.connectionAccount)
            }
        }
        _ = try await wallet.installProfile(original, key: NativeWallet.KeyRecord(seed: Data(repeating: 61, count: 64), phrase: nil, network: "xbt-regtest"))
        let originalAddress = try await wallet.address(ark: false)
        let count = try await wallet.profiles().count
        let mismatched = RecoveryArchive(network: archive.network, walletID: archive.walletID, createdAt: archive.createdAt,
                                         seed: Data(repeating: 30, count: 64), recoveryState: archive.recoveryState)
        do { try await wallet.restoreIntoEmptyWallet(mismatched); XCTFail("Wrong wallet archive installed") }
        catch { XCTAssertTrue(error is WalletFailure) }
        let afterRejection = try await wallet.selectedProfile()
        XCTAssertEqual(afterRejection?.id, original.id)
        let rejectedCount = try await wallet.profiles().count
        XCTAssertEqual(rejectedCount, count)
        let priorAddresses = try await wallet.onchainAddresses(start: 0)
        XCTAssertTrue(priorAddresses.entries.contains { $0["address"] as? String == originalAddress })

        try await wallet.restoreIntoEmptyWallet(archive)
        let selected = try await wallet.selectedProfile()
        let restored = try XCTUnwrap(selected)
        created.append(restored)
        XCTAssertNotEqual(restored.id, original.id)
        let restoredCount = try await wallet.profiles().count
        XCTAssertEqual(restoredCount, count + 1)
        let pending = try await wallet.outgoingPayment()
        XCTAssertEqual(pending?["attempt_id"] as? String, fixture["attemptID"] as? String)
        XCTAssertEqual(pending?["state"] as? String, "unknown")
        do { try await wallet.restoreIntoEmptyWallet(archive); XCTFail("Duplicate wallet installed") }
        catch { XCTAssertTrue(error is WalletFailure) }
        let afterDuplicate = try await wallet.selectedProfile()
        XCTAssertEqual(afterDuplicate?.id, restored.id)
        let duplicateCount = try await wallet.profiles().count
        XCTAssertEqual(duplicateCount, count + 1)
        // Read through a fresh adapter so cached catalog state cannot mask a
        // missing selection commit in the device-only Keychain.
        let persistedSelection = try await NativeWallet().selectedProfile()
        XCTAssertEqual(persistedSelection?.id, restored.id)
        try await wallet.activate(original.id)
        let originalAddresses = try await wallet.onchainAddresses(start: 0)
        XCTAssertTrue(originalAddresses.entries.contains { $0["address"] as? String == originalAddress })
        try await wallet.activate(restored.id)
        let recovered = try await wallet.outgoingPayment()
        XCTAssertEqual(recovered?["attempt_id"] as? String, fixture["attemptID"] as? String)
        XCTAssertEqual(recovered?["state"] as? String, "unknown")
    }

    func testAndroidArchivePreservesAccountsAndPendingAttempt() async throws {
        let bundle = Bundle(for: Self.self)
        func resource(_ name: String) throws -> Data {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: nil, subdirectory: "NativeBackupFixtures"))
            return try Data(contentsOf: url)
        }
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: resource("native-v2-regtest.json")) as? [String: Any])
        let recoveryKey = try XCTUnwrap(fixture["publicRecoveryKey"] as? String)
        let archive = try EncryptedBackup.open(resource("android-v2-regtest.pcbackup"), recoveryKey: recoveryKey)
        XCTAssertEqual(archive.network, "xbt-regtest")
        XCTAssertTrue(archive.seed == Data(repeating: 29, count: 64))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-interop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func call(_ operation: String, _ fields: [String: Any] = [:], seed: Data? = nil) throws -> [String: Any] {
            var request = fields
            request["op"] = operation
            let input = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
            let output = input.withCString { request in
                (seed ?? archive.seed).withUnsafeBytes { bytes -> String in
                    guard let reply = paperclip_mobile_call(request, bytes.bindMemory(to: UInt8.self).baseAddress) else { return "{}" }
                    defer { paperclip_mobile_free(reply) }
                    return String(cString: reply)
                }
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        }
        func ok(_ operation: String, _ fields: [String: Any] = [:]) throws -> [String: Any] {
            let result = try call(operation, fields)
            return try XCTUnwrap(result["ok"] as? [String: Any], "Synthetic native \(operation) failed")
        }
        func input(_ network: String = "xbt-regtest", at path: URL? = nil) -> [String: Any] {
            ["network": network, "directory": (path ?? directory).path, "database": archive.recoveryState.base64EncodedString()]
        }
        _ = try ok("close")
        defer { _ = try? call("close"); try? FileManager.default.removeItem(at: directory) }
        XCTAssertNotNil(try call("verify_backup", input(), seed: Data(repeating: 30, count: 64))["error"])
        XCTAssertNotNil(try call("verify_backup", input("xbt-mainnet"))["error"])
        XCTAssertEqual(try ok("verify_backup", input())["verified"] as? Bool, true)
        let restored = directory.appendingPathComponent("restored")
        _ = try ok("restore", input(at: restored))
        _ = try ok("open", ["network": "xbt-regtest", "directory": restored.path])
        XCTAssertEqual(try ok("overview_onchain")["account"] as? String, "segwit")
        let attempt = try XCTUnwrap(ok("outgoing_payment")["attempt"] as? [String: Any])
        XCTAssertEqual(attempt["attempt_id"] as? String, fixture["attemptID"] as? String)
        XCTAssertEqual(attempt["payment_hash"] as? String, fixture["paymentHash"] as? String)
        XCTAssertEqual(attempt["state"] as? String, "unknown")
        let snapshot = try ok("backup")
        XCTAssertEqual(snapshot["recovery_version"] as? Int, 2)
        let database = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(snapshot["database"] as? String)))
        let exported = RecoveryArchive(network: archive.network, walletID: archive.walletID, createdAt: archive.createdAt,
                                       seed: archive.seed, recoveryState: database)
        let encrypted = try EncryptedBackup.seal(exported, recoveryKey: recoveryKey)
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("backup-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try encrypted.write(to: output.appendingPathComponent("ios-v2-regtest.pcbackup"), options: .atomic)
        XCTAssertEqual(try ok("address_onchain")["address"] as? String, fixture["nextSegwitAddress"] as? String)
        _ = try ok("select_onchain_account", ["account": "taproot"])
        XCTAssertEqual(try ok("address_onchain")["address"] as? String, fixture["nextTaprootAddress"] as? String)
        for operation in ["quote", "quote_onchain", "send", "send_onchain"] {
            let error = try call(operation)["error"] as? String ?? ""
            XCTAssertTrue(error.contains("previous payment"), "Restored approval or replay was allowed")
        }
    }
}
