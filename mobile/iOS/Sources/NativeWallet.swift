import Foundation
import Security
import PaperclipMobile

struct WalletFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum WalletKeychain {
    static func saveConnection(_ data: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "xyz.paperclippool.wallet.preview", kSecAttrAccount as String: "regtest-connection-v1"]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { try insert(data, account: "regtest-connection-v1") }
        else if status != errSecSuccess { throw WalletFailure(message: "Could not save the connection in Keychain.") }
    }
    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "xyz.paperclippool.wallet.preview", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WalletFailure(message: "Unlock the device to access wallet storage (\(status)).")
        }
        return data
    }
    static func insert(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "xyz.paperclippool.wallet.preview", kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false, kSecValueData as String: data]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw WalletFailure(message: "Could not save wallet key. Existing keys were not replaced.")
        }
    }
}

// One actor owns the session. Blocking FFI work runs on its own serial queue.
// Background cancellation never resubmits a payment or deletes persistent state.
actor NativeWallet: WalletEngine, WalletBackupEngine {
    static let shared = NativeWallet()
    private let queue = DispatchQueue(label: "paperclip.native.wallet", qos: .userInitiated)
    private var opened = false
    private var opening: Task<String, Error>?
    private var connected = false
    private var fingerprint = ""
    private let keyAccount = "regtest-seed-v1"
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperclipRegtest", isDirectory: true)
    }

    private func call(_ input: [String: Any], seed: Data? = nil) async throws -> [String: Any] {
        guard let key = try seed ?? WalletKeychain.read(keyAccount), key.count == 64 else {
            throw WalletFailure(message: "Create or restore a test wallet first.")
        }
        let encoded = try JSONSerialization.data(withJSONObject: input)
        let request = String(decoding: encoded, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let reply = request.withCString { request in
                        key.withUnsafeBytes { bytes in paperclip_mobile_call(request, bytes.bindMemory(to: UInt8.self).baseAddress) }
                    }
                    guard let reply else { throw WalletFailure(message: "Native wallet did not respond.") }
                    defer { paperclip_mobile_free(reply) }
                    let value = try JSONSerialization.jsonObject(with: Data(String(cString: reply).utf8)) as? [String: Any]
                    if let error = value?["error"] as? String { throw WalletFailure(message: error) }
                    guard let output = value?["ok"] as? [String: Any] else { throw WalletFailure(message: "Invalid native response.") }
                    continuation.resume(returning: output)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func open(create: Bool = false) async throws -> String {
        if opened { return fingerprint }
        if let opening { return try await opening.value }
        let task = Task { try await self.openStorage(create: create) }
        opening = task
        defer { opening = nil }
        return try await task.value
    }
    private func openStorage(create: Bool) async throws -> String {
        if try WalletKeychain.read(keyAccount) == nil {
            guard create, !FileManager.default.fileExists(atPath: directory.appendingPathComponent("db.sqlite").path) else {
                throw WalletFailure(message: "No key is available. Restore the encrypted full-wallet backup.")
            }
            var seed = Data(count: 64)
            let result = seed.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 64, $0.baseAddress!) }
            guard result == errSecSuccess else { throw WalletFailure(message: "Secure random generation failed.") }
            try WalletKeychain.insert(seed, account: keyAccount)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var protected = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("db.sqlite").path)
        guard create || exists else { throw WalletFailure(message: "Wallet database missing. Restore a full backup.") }
        let result = try await call(["op": exists ? "open" : "create", "directory": directory.path, "network": "xbt-regtest"])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.appendingPathComponent("db.sqlite").path)
        fingerprint = result["fingerprint"] as? String ?? ""
        opened = true
        return fingerprint
    }

    func address(ark: Bool) async throws -> String {
        _ = try await open()
        if ark { try await ensureConnected() }
        let result = try await call(["op": ark ? "address_ark" : "address_onchain"])
        guard let address = result["address"] as? String else { throw WalletFailure(message: "Address unavailable.") }
        return address
    }

    func connect(server: String, rpc: String, username: String, password: String) async throws {
        _ = try await open()
        for text in [server, rpc] {
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else {
                throw WalletFailure(message: "Use a valid HTTP(S) test endpoint without credentials in the URL.")
            }
        }
        var config = try await call(["op": "config_template"])
        config["server_address"] = server
        config["esplora_address"] = NSNull()
        config["bitcoind_address"] = rpc
        config["bitcoind_user"] = username
        config["bitcoind_pass"] = password
        config["user_agent"] = "paperclip-ios/0.1.0"
        _ = try await call(["op": "connect", "config": config])
        connected = true
        try WalletKeychain.saveConnection(JSONSerialization.data(withJSONObject: config))
    }

    private func ensureConnected() async throws {
        _ = try await open()
        if connected { return }
        guard let data = try WalletKeychain.read("regtest-connection-v1"),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WalletFailure(message: "Configure the test backend first.")
        }
        _ = try await call(["op": "connect", "config": config])
        connected = true
    }
    func balances() async throws -> [String: Any] {
        try await ensureConnected()
        return try await call(["op": "sync"])
    }
    func synchronize() async throws -> WalletSnapshot {
        let result = try await balances()
        guard let tip = result["tip"] as? Int, let vtxos = result["vtxos"] as? [[String: Any]] else {
            throw WalletFailure(message: "Incomplete wallet sync.")
        }
        return WalletSnapshot(tip: tip, observedAt: Date(), estimatedBlockSeconds: 600,
            vtxos: try JSONDecoder().decode([VTXO].self, from: JSONSerialization.data(withJSONObject: vtxos)))
    }
    func refreshEligible() async throws { _ = try await call(["op": "refresh"]) }
    func activity() async throws -> [String: Any] {
        try await ensureConnected()
        return try await call(["op": "activity"])
    }
    func quote(destination: String, amount: UInt64, onchain: Bool = false) async throws -> [String: Any] {
        try await ensureConnected()
        return try await call(["op": onchain ? "quote_onchain" : "quote", "destination": destination, "amount_sat": amount])
    }
    func send(destination: String, amount: UInt64, total: UInt64, onchain: Bool = false) async throws -> [String: Any] {
        try await call(["op": onchain ? "send_onchain" : "send", "destination": destination, "amount_sat": amount, "total_sat": total])
    }
    func exportRecoveryArchive() async throws -> RecoveryArchive {
        _ = try await open()
        let result = try await call(["op": "backup"])
        guard let encoded = result["database"] as? String, let database = Data(base64Encoded: encoded),
              let seed = try WalletKeychain.read(keyAccount) else { throw BackupError.invalidArchive }
        return RecoveryArchive(network: "xbt-regtest", walletID: fingerprint, createdAt: Date(), seed: seed, recoveryState: database)
    }
    func restoreIntoEmptyWallet(_ archive: RecoveryArchive) async throws {
        try archive.validate()
        guard !opened, archive.network == "xbt-regtest", !FileManager.default.fileExists(atPath: directory.path) else {
            throw WalletFailure(message: "Restore requires an empty regtest wallet. Existing data was not replaced.")
        }
        if let saved = try WalletKeychain.read(keyAccount) {
            guard saved == archive.seed else { throw WalletFailure(message: "A different wallet key already exists.") }
        } else { try WalletKeychain.insert(archive.seed, account: keyAccount) }
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await call(["op": "restore", "network": archive.network, "directory": directory.path,
            "database": archive.recoveryState.base64EncodedString()], seed: archive.seed)
        _ = try await open()
    }
}
