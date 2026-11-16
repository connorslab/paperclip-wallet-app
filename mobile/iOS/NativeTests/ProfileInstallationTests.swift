import XCTest
import PaperclipMobile

/// Minimal native test host: isolated container and Keychain access group.
final class ProfileInstallationTests: XCTestCase {
    func testExistingKeyAndConnectionAreNeverReplacedOrRemoved() async throws {
        for collisionIsKey in [true, false] {
            let wallet = NativeWallet()
            let previous = try await wallet.selectedProfile()
            let profile = WalletProfile(name: "Existing record fixture", kind: .hot, network: "xbt-regtest")
            let account = collisionIsKey ? profile.keyAccount : profile.connectionAccount
            let existing = Data("Existing record must survive setup".utf8)
            try WalletKeychain.insert(existing, account: account)
            defer {
                try? WalletKeychain.delete(profile.keyAccount)
                try? WalletKeychain.delete(profile.connectionAccount)
            }
            let key = NativeWallet.KeyRecord(seed: Data(repeating: 37, count: 64), phrase: nil, network: "xbt-regtest")
            do {
                _ = try await wallet.installProfile(profile, key: key, connection: WalletConnection())
                XCTFail("Installation replaced an existing Keychain record")
            } catch { XCTAssertTrue(error is WalletFailure) }
            XCTAssertEqual(try WalletKeychain.read(account), existing)
            if !collisionIsKey { XCTAssertNil(try WalletKeychain.read(profile.keyAccount)) }
            let selected = try await wallet.selectedProfile()
            XCTAssertEqual(selected, previous)
        }
    }

    func testFailedInstallationReopensThePreviousWallet() async throws {
        let wallet = NativeWallet()
        let savedCatalog = try WalletKeychain.read("wallet-catalog-v1")
        let original = WalletProfile(name: "Original fixture", kind: .hot, network: "xbt-regtest")
        let attempted = WalletProfile(name: "Failed fixture", kind: .hot, network: "xbt-regtest")
        let originalKey = NativeWallet.KeyRecord(seed: Data(repeating: 19, count: 64), phrase: nil, network: "xbt-regtest")
        let attemptedKey = NativeWallet.KeyRecord(seed: Data(repeating: 37, count: 64), phrase: nil, network: "xbt-regtest")
        let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperclipWallets", isDirectory: true)
        defer {
            "{\"op\":\"close\"}".withCString { request in
                originalKey.seed.withUnsafeBytes { bytes in
                    if let reply = paperclip_mobile_call(request, bytes.bindMemory(to: UInt8.self).baseAddress) { paperclip_mobile_free(reply) }
                }
            }
            if let savedCatalog { try? WalletKeychain.save(savedCatalog, account: "wallet-catalog-v1") }
            else { try? WalletKeychain.delete("wallet-catalog-v1") }
            for profile in [original, attempted] {
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(profile.id))
                try? WalletKeychain.delete(profile.keyAccount)
                try? WalletKeychain.delete(profile.connectionAccount)
            }
        }
        _ = try await wallet.installProfile(original, key: originalKey, connection: WalletConnection())
        let originalAddress = try await wallet.address(ark: false)
        let marker = Data("Existing file must survive setup".utf8)
        let blocked = parent.appendingPathComponent(attempted.id)
        try marker.write(to: blocked, options: .withoutOverwriting)
        do {
            _ = try await wallet.installProfile(attempted, key: attemptedKey, connection: WalletConnection())
            XCTFail("Installation accepted a blocked database directory")
        } catch { XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain) }
        let selection = try await wallet.selectedProfile()
        XCTAssertEqual(selection?.id, original.id)
        // Query the already-open native session directly. Calling the adapter's
        // address() would lazily open it and allocate a different receive address.
        let reply: String = "{\"op\":\"addresses_onchain\"}".withCString { request in
            originalKey.seed.withUnsafeBytes { bytes in
                guard let output = paperclip_mobile_call(request, bytes.bindMemory(to: UInt8.self).baseAddress) else { return "" }
                defer { paperclip_mobile_free(output) }
                return String(cString: output)
            }
        }
        let response = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        XCTAssertNotNil(response?["ok"], "Failed setup left the previous native wallet closed")
        XCTAssertTrue(reply.contains(originalAddress), "Previous wallet lost its receive address")
        XCTAssertNotNil(try WalletKeychain.read(original.keyAccount))
        XCTAssertNil(try WalletKeychain.read(attempted.keyAccount))
        XCTAssertNil(try WalletKeychain.read(attempted.connectionAccount))
        XCTAssertEqual(try Data(contentsOf: blocked), marker)
    }

    func testFailedInstallationRemovesOnlyKeysItCreated() async throws {
        let wallet = NativeWallet()
        let previous = try await wallet.selectedProfile()
        let savedCatalog = try WalletKeychain.read("wallet-catalog-v1")
        let profile = WalletProfile(name: "Failed installation fixture", kind: .hot, network: "xbt-regtest")
        let key = NativeWallet.KeyRecord(seed: Data(repeating: 37, count: 64), phrase: nil, network: "xbt-regtest")
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let parent = root.appendingPathComponent("PaperclipWallets", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let blocked = parent.appendingPathComponent(profile.id)
        let marker = Data("Existing file must survive failed setup".utf8)
        try marker.write(to: blocked, options: .withoutOverwriting)
        defer {
            // Close this isolated native session before removing its test database.
            "{\"op\":\"close\"}".withCString { request in
                key.seed.withUnsafeBytes { bytes in
                    if let reply = paperclip_mobile_call(request, bytes.bindMemory(to: UInt8.self).baseAddress) { paperclip_mobile_free(reply) }
                }
            }
            if let savedCatalog { try? WalletKeychain.save(savedCatalog, account: "wallet-catalog-v1") }
            else { try? WalletKeychain.delete("wallet-catalog-v1") }
            try? FileManager.default.removeItem(at: blocked)
            try? WalletKeychain.delete(profile.keyAccount)
            try? WalletKeychain.delete(profile.connectionAccount)
        }
        do {
            _ = try await wallet.installProfile(profile, key: key, connection: WalletConnection())
            XCTFail("Installation accepted a file in place of its database directory")
        } catch {
            // The file makes real storage creation fail after Keychain insertion.
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
        let selected = try await wallet.selectedProfile()
        XCTAssertEqual(selected, previous)
        XCTAssertNil(try WalletKeychain.read(profile.keyAccount), "Failed setup retained an unregistered key")
        XCTAssertNil(try WalletKeychain.read(profile.connectionAccount), "Failed setup retained unregistered connection settings")
        XCTAssertEqual(try Data(contentsOf: blocked), marker)
        try FileManager.default.removeItem(at: blocked)
        _ = try await wallet.installProfile(profile, key: key, connection: WalletConnection())
        let restoredSelection = try await wallet.selectedProfile()
        XCTAssertEqual(restoredSelection?.id, profile.id)
        let address = try await wallet.address(ark: false)
        XCTAssertTrue(address.hasPrefix("bcrt1"))
    }
}
