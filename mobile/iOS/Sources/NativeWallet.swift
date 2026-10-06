import Foundation
import Security
import PaperclipMobile

struct WalletFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum WalletKeychain {
    static func saveConnection(_ data: Data) throws { try save(data, account: "wallet-connection-v2") }
    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "xyz.paperclippool.wallet.preview", kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { try insert(data, account: account) }
        else if status != errSecSuccess { throw WalletFailure(message: "Could not save data in Keychain.") }
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
    private var provisioning = false
    private var opening: Task<String, Error>?
    private var connected = false
    private var foreground = true
    private var fingerprint = ""
    private struct KeyRecord: Codable { let seed: Data; let phrase: String?; let network: String }
    private func record() throws -> KeyRecord? {
        if let data = try WalletKeychain.read("wallet-key-v2") { return try JSONDecoder().decode(KeyRecord.self, from: data) }
        if let seed = try WalletKeychain.read("regtest-seed-v1") { return KeyRecord(seed: seed, phrase: nil, network: "xbt-regtest") }
        return nil
    }
    private var network = "xbt-mainnet"
    func hasWallet() throws -> Bool { try record() != nil }
    func walletNetwork() throws -> String { try record()?.network ?? "xbt-mainnet" }
    func generatePhrase() async throws -> String {
        let result = try await call(["op": "seed_generate"], seed: Data(repeating: 0, count: 64))
        guard let phrase = result["phrase"] as? String else { throw WalletFailure(message: "Seed generation failed.") }
        return phrase
    }
    func create(phrase: String, confirmation: String, network: String) async throws -> String {
        guard !provisioning else { throw WalletFailure(message: "Wallet setup is already in progress.") }
        provisioning = true; defer { provisioning = false }
        guard try record() == nil, SeedVerification.matches(phrase: phrase, confirmation: confirmation),
              ["xbt-mainnet", "xbt-regtest"].contains(network) else { throw WalletFailure(message: "Verify every seed word before creating the wallet.") }
        let result = try await call(["op": "seed_derive", "phrase": phrase], seed: Data(repeating: 0, count: 64))
        guard let encoded = result["seed"] as? String, let seed = Data(base64Encoded: encoded), seed.count == 64 else {
            throw WalletFailure(message: "Invalid seed phrase.")
        }
        // Re-check after the FFI await. Never replace another setup or restored wallet.
        guard try record() == nil else { throw WalletFailure(message: "A wallet already exists.") }
        try WalletKeychain.insert(JSONEncoder().encode(KeyRecord(seed: seed, phrase: phrase, network: network)), account: "wallet-key-v2")
        return try await open(create: true)
    }
    func savedConnection() throws -> WalletConnection? {
        guard let data = try WalletKeychain.read("wallet-connection-v2") else { return nil }
        return try JSONDecoder().decode(WalletConnection.self, from: data)
    }
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(network == "xbt-regtest" ? "PaperclipRegtest" : "PaperclipMainnet", isDirectory: true)
    }

    private func call(_ input: [String: Any], seed: Data? = nil) async throws -> [String: Any] {
        guard let key = try seed ?? record()?.seed, key.count == 64 else {
            throw WalletFailure(message: "Create or restore a wallet first.")
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
        guard let saved = try record() else { throw WalletFailure(message: "Create or restore a wallet first.") }
        network = saved.network
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var protected = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("db.sqlite").path)
        guard create || exists else { throw WalletFailure(message: "Wallet database missing. Restore a full backup.") }
        let result = try await call(["op": exists ? "open" : "create", "directory": directory.path, "network": network])
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

    func connect(_ settings: WalletConnection) async throws {
        try settings.validate()
        _ = try await open()
        var config = try await call(["op": "config_template"])
        config["server_address"] = settings.arkServer
        config["esplora_address"] = settings.backend == .esplora ? settings.endpoint : NSNull()
        config["electrum_address"] = settings.backend == .electrum ? settings.endpoint : NSNull()
        config["electrum_certificate_sha256"] = settings.certificateSHA256.isEmpty ? NSNull() : settings.certificateSHA256
        config["bitcoind_address"] = settings.backend == .rpc ? settings.endpoint : NSNull()
        config["bitcoind_user"] = settings.username
        config["bitcoind_pass"] = settings.password
        config["socks5_proxy"] = settings.useTor ? settings.torProxy : NSNull()
        config["user_agent"] = "paperclip-ios/0.2.0"
        connected = false
        var request: [String: Any] = ["op": "connect", "config": config]
        if let rpc = settings.arkRPC {
            // RPC cannot use the Rust backend's SOCKS transport. Never bypass a Tor request.
            guard !settings.useTor else { throw ConnectionError.unsupportedTor }
            var arkConfig = config
            arkConfig["electrum_address"] = NSNull()
            arkConfig["esplora_address"] = NSNull()
            arkConfig["bitcoind_address"] = rpc.endpoint
            arkConfig["bitcoind_user"] = rpc.username
            arkConfig["bitcoind_pass"] = rpc.password
            request["ark_config"] = arkConfig
        }
        _ = try await call(request)
        try WalletKeychain.saveConnection(JSONEncoder().encode(settings))
        connected = true
        _ = try await call(["op": "receive_listen", "enabled": foreground])
    }
    func setForeground(_ active: Bool) async {
        foreground = active
        guard opened && connected else { return }
        _ = try? await call(["op": "receive_listen", "enabled": active])
    }
    // Retained for the regtest diagnostic workbench.
    func connect(server: String, rpc: String, username: String, password: String) async throws {
        var settings = WalletConnection(); settings.backend = .rpc; settings.arkServer = server
        settings.endpoint = rpc; settings.username = username; settings.password = password
        try await connect(settings)
    }
    private func ensureConnected() async throws {
        _ = try await open()
        if connected { return }
        guard let settings = try savedConnection() else { throw WalletFailure(message: "Configure a chain connection in Settings.") }
        try await connect(settings)
    }
    func operation(_ op: String, fields: [String: Any] = [:]) async throws -> [String: Any] {
        try await ensureConnected()
        var input = fields; input["op"] = op
        return try await call(input)
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
              let saved = try record() else { throw BackupError.invalidArchive }
        return RecoveryArchive(network: network, walletID: fingerprint, createdAt: Date(), seed: saved.seed, recoveryState: database, seedPhrase: saved.phrase)
    }
    func restoreIntoEmptyWallet(_ archive: RecoveryArchive) async throws {
        guard !provisioning else { throw WalletFailure(message: "Wallet setup is already in progress.") }
        provisioning = true; defer { provisioning = false }
        try archive.validate()
        guard !opened, try record() == nil else {
            throw WalletFailure(message: "Restore requires an empty wallet. Existing data was not replaced.")
        }
        network = archive.network
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw WalletFailure(message: "Wallet storage already exists.") }
        if let phrase = archive.seedPhrase {
            let derived = try await call(["op": "seed_derive", "phrase": phrase], seed: Data(repeating: 0, count: 64))
            guard derived["seed"] as? String == archive.seed.base64EncodedString() else { throw BackupError.invalidArchive }
        }
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await call(["op": "restore", "network": archive.network, "directory": directory.path,
            "database": archive.recoveryState.base64EncodedString()], seed: archive.seed)
        try WalletKeychain.insert(JSONEncoder().encode(KeyRecord(seed: archive.seed, phrase: archive.seedPhrase, network: network)), account: "wallet-key-v2")
        _ = try await open()
    }
}
