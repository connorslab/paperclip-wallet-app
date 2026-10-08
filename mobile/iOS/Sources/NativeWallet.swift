import Foundation
import Security
import PaperclipMobile

struct WalletFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum WalletKeychain {
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
    private var catalog: WalletCatalog?
    private var operations = 0
    private var transitioning = false
    private func beginOperation() throws {
        guard !transitioning else { throw WalletFailure(message: "Wallet is switching. Try again in a moment.") }
        operations += 1
    }
    private func loadedCatalog() throws -> WalletCatalog {
        if let catalog { return catalog }
        if let data = try WalletKeychain.read("wallet-catalog-v1") {
            let saved = try JSONDecoder().decode(WalletCatalog.self, from: data)
            guard saved.wallets.isEmpty || saved.selected != nil else { throw WalletFailure(message: "Wallet selection is invalid.") }
            catalog = saved; return saved
        }
        var saved = WalletCatalog()
        if let data = try WalletKeychain.read("wallet-key-v2") {
            let key = try JSONDecoder().decode(KeyRecord.self, from: data)
            try saved.add(WalletProfile(id: "legacy", name: "My Paperclip wallet", kind: .hot, network: key.network))
        } else if let seed = try WalletKeychain.read("regtest-seed-v1") {
            try WalletKeychain.insert(JSONEncoder().encode(KeyRecord(seed: seed, phrase: nil, network: "xbt-regtest")), account: "wallet-key-v2")
            try saved.add(WalletProfile(id: "legacy", name: "Regtest wallet", kind: .hot, network: "xbt-regtest"))
        }
        try saveCatalog(saved)
        return saved
    }
    private func saveCatalog(_ value: WalletCatalog) throws {
        try WalletKeychain.save(JSONEncoder().encode(value), account: "wallet-catalog-v1")
        catalog = value
    }
    func holdMaintenanceWallet() throws -> WalletProfile? {
        let profile = try loadedCatalog().selected
        guard profile?.supportsArk == true else { return nil }
        try beginOperation(); return profile
    }
    func releaseMaintenanceWallet() { operations -= 1 }
    func profiles() throws -> [WalletProfile] { try loadedCatalog().wallets }
    func selectedProfile() throws -> WalletProfile? { try loadedCatalog().selected }
    func rename(id: String, name: String) throws {
        guard !transitioning else { throw WalletFailure(message: "Wait for the wallet switch to finish.") }
        var saved = try loadedCatalog()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, let index = saved.wallets.firstIndex(where: { $0.id == id }) else { throw WalletFailure(message: "Enter a wallet name up to 60 characters.") }
        saved.wallets[index].name = name; try saveCatalog(saved)
    }
    func activate(_ id: String) async throws {
        guard operations == 0, !provisioning, !transitioning, opening == nil else { throw WalletFailure(message: "Wait for the current wallet operation to finish, then switch.") }
        var next = try loadedCatalog()
        guard next.wallets.contains(where: { $0.id == id }) else { throw WalletFailure(message: "Wallet not found.") }
        if next.selectedID == id && opened { return }
        transitioning = true; defer { transitioning = false }
        let previous = next
        if opened { _ = try await call(["op": "close"]) }
        opened = false; connected = false; fingerprint = ""
        next.selectedID = id
        catalog = next
        do {
            _ = try await openStorage(create: false)
            try saveCatalog(next)
        } catch {
            if opened { _ = try? await call(["op": "close"]) }
            opened = false; connected = false; catalog = previous
            if previous.selected != nil { _ = try? await openStorage(create: false) }
            throw error
        }
    }
    private var provisioning = false
    private var opening: Task<String, Error>?
    private var connected = false
    private var foreground = true
    private var fingerprint = ""
    private struct KeyRecord: Codable { let seed: Data; let phrase: String?; let network: String }
    private func record() throws -> KeyRecord? {
        guard let profile = try loadedCatalog().selected, let data = try WalletKeychain.read(profile.keyAccount) else { return nil }
        return try JSONDecoder().decode(KeyRecord.self, from: data)
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
        try await addHotWallet(name: "My Paperclip wallet", phrase: phrase, confirmation: confirmation, network: network)
    }
    func addHotWallet(name: String, phrase: String, confirmation: String, network: String, connection: WalletConnection? = nil) async throws -> String {
        guard SeedVerification.matches(phrase: phrase, confirmation: confirmation), ["xbt-mainnet", "xbt-regtest"].contains(network) else { throw WalletFailure(message: "Verify every seed word before creating the wallet.") }
        let result = try await call(["op": "seed_derive", "phrase": phrase], seed: Data(repeating: 0, count: 64))
        guard let encoded = result["seed"] as? String, let seed = Data(base64Encoded: encoded), seed.count == 64 else { throw WalletFailure(message: "Invalid seed phrase.") }
        return try await installProfile(WalletProfile(name: name, kind: .hot, network: network), key: KeyRecord(seed: seed, phrase: phrase, network: network), connection: connection)
    }
    func addPublicWallet(name: String, value: String, script: String, origin: String, network: String, hardware: Bool, connection: WalletConnection? = nil) async throws -> String {
        let result = try await call(["op": "validate_public_wallet", "public_key": value.trimmingCharacters(in: .whitespacesAndNewlines), "script": script,
            "origin": origin, "network": network, "hardware": hardware], seed: Data(repeating: 0, count: 64))
        guard let descriptor = result["receive"] as? String else { throw WalletFailure(message: "Invalid public wallet.") }
        // This random value identifies the local database. It is not the hardware wallet's seed.
        var identity = Data(count: 64)
        let success = identity.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 64, $0.baseAddress!) }
        guard success == errSecSuccess else { throw WalletFailure(message: "Could not initialize wallet storage.") }
        return try await installProfile(WalletProfile(name: name, kind: hardware ? .hardware : .watch, network: network, descriptor: descriptor),
            key: KeyRecord(seed: identity, phrase: nil, network: network), connection: connection)
    }
    private func installProfile(_ profile: WalletProfile, key: KeyRecord, archive: RecoveryArchive? = nil, connection: WalletConnection? = nil) async throws -> String {
        guard operations == 0, !provisioning, !transitioning, opening == nil else { throw WalletFailure(message: "Wait for the current wallet operation to finish.") }
        let previous = try loadedCatalog()
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, profile.name.count <= 60 else { throw WalletFailure(message: "Enter a wallet name up to 60 characters.") }
        for existing in previous.wallets {
            if let data = try WalletKeychain.read(existing.keyAccount), let stored = try? JSONDecoder().decode(KeyRecord.self, from: data), stored.seed == key.seed && stored.network == key.network {
                throw WalletFailure(message: "This wallet is already saved as \(existing.name). Switch to it instead.")
            }
            if let descriptor = profile.descriptor, existing.descriptor == descriptor && existing.network == profile.network { throw WalletFailure(message: "This public wallet is already saved as \(existing.name).") }
        }
        let settings = try connection ?? savedConnection() ?? WalletConnection()
        try settings.validate()
        provisioning = true; transitioning = true
        defer { provisioning = false; transitioning = false }
        if opened { _ = try await call(["op": "close"]) }
        opened = false; connected = false; fingerprint = ""
        var next = previous; try next.add(profile)
        do {
            try WalletKeychain.insert(JSONEncoder().encode(key), account: profile.keyAccount)
            try WalletKeychain.save(JSONEncoder().encode(settings), account: profile.connectionAccount)
            catalog = next
            if let archive {
                network = archive.network
                var parent = directory.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                var protection = URLResourceValues(); protection.isExcludedFromBackup = true
                try parent.setResourceValues(protection)
                _ = try await call(["op": "restore", "network": network, "directory": directory.path, "database": archive.recoveryState.base64EncodedString()], seed: key.seed)
            }
            let id = try await openStorage(create: archive == nil)
            try saveCatalog(next)
            return id
        } catch {
            if opened { _ = try? await call(["op": "close"]) }
            opened = false; connected = false; catalog = previous
            if previous.selected != nil { _ = try? await openStorage(create: false) }
            throw error
        }
    }
    func savedConnection() throws -> WalletConnection? {
        guard let data = try WalletKeychain.read(loadedCatalog().selected?.connectionAccount ?? "wallet-connection-v2") else { return nil }
        return try JSONDecoder().decode(WalletConnection.self, from: data)
    }
    func saveConnection(_ settings: WalletConnection) throws {
        guard !transitioning else { throw WalletFailure(message: "Wait for the wallet switch to finish.") }
        try settings.validate()
        try WalletKeychain.save(JSONEncoder().encode(settings), account: loadedCatalog().selected?.connectionAccount ?? "wallet-connection-v2")
    }
    private var directory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let profile = catalog?.selected, profile.id != "legacy" {
            return root.appendingPathComponent("PaperclipWallets", isDirectory: true).appendingPathComponent(profile.id, isDirectory: true)
        }
        return root.appendingPathComponent(network == "xbt-regtest" ? "PaperclipRegtest" : "PaperclipMainnet", isDirectory: true)
    }

    private func call(_ input: [String: Any], seed: Data? = nil) async throws -> [String: Any] {
        guard let key = try seed ?? record()?.seed, key.count == 64 else {
            throw WalletFailure(message: "Create or restore a wallet first.")
        }
        let encoded = try JSONSerialization.data(withJSONObject: input)
        let request = String(decoding: encoded, as: UTF8.self)
        do {
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
        } catch {
            if error.localizedDescription.lowercased().contains("broken pipe") {
                // Rebuild the backend on the next request, without replaying an
                // operation that might already have reached the server.
                connected = false
            }
            throw error
        }
    }

    func open(create: Bool = false) async throws -> String {
        try beginOperation(); defer { operations -= 1 }
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
        let profile = try loadedCatalog().selected
        var request: [String: Any] = ["op": exists ? "open" : "create", "directory": directory.path, "network": network, "kind": profile?.kind.rawValue ?? "hot"]
        if let descriptor = profile?.descriptor { request["descriptor"] = descriptor }
        let result = try await call(request)
        opened = true
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.appendingPathComponent("db.sqlite").path)
        fingerprint = result["fingerprint"] as? String ?? ""
        return fingerprint
    }

    func address(ark: Bool) async throws -> String {
        try beginOperation(); defer { operations -= 1 }
        _ = try await open()
        if ark { try await ensureConnected() }
        let result = try await call(["op": ark ? "address_ark" : "address_onchain"])
        guard let address = result["address"] as? String else { throw WalletFailure(message: "Address unavailable.") }
        return address
    }

    private func chainConfiguration(_ settings: WalletConnection) async throws -> [String: Any] {
        try settings.validate()
        var config = try await call(["op": "config_template"])
        config["server_address"] = settings.arkServer
        config["esplora_address"] = settings.backend == .esplora ? settings.endpoint : NSNull()
        config["electrum_address"] = settings.backend == .electrum ? settings.endpoint : NSNull()
        config["electrum_certificate_sha256"] = settings.certificateSHA256.isEmpty ? NSNull() : settings.certificateSHA256
        config["bitcoind_address"] = settings.backend == .rpc ? settings.endpoint : NSNull()
        config["bitcoind_user"] = settings.username
        config["bitcoind_pass"] = settings.password
        config["socks5_proxy"] = settings.useTor ? try await EmbeddedTor.shared.proxy(for: settings.torProxy) : NSNull()
        config["user_agent"] = "paperclip-ios/0.2.0"
        return config
    }
    private func publicWalletFields(_ id: String, withConnection: Bool) async throws -> [String: Any] {
        let catalog = try loadedCatalog()
        guard catalog.selected?.supportsArk == true,
              let profile = catalog.wallets.first(where: { $0.id == id }), profile.kind == .hardware,
              profile.network == catalog.selected?.network, let descriptor = profile.descriptor,
              let saved = try WalletKeychain.read(profile.keyAccount) else {
            throw WalletFailure(message: "Choose a saved QR wallet on the same network as this mobile Ark wallet.")
        }
        let key = try JSONDecoder().decode(KeyRecord.self, from: saved)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let path = root.appendingPathComponent("PaperclipWallets", isDirectory: true).appendingPathComponent(profile.id, isDirectory: true)
        var fields: [String: Any] = ["directory": path.path, "descriptor": descriptor, "identity": key.seed.base64EncodedString()]
        if withConnection {
            let settings: WalletConnection
            if let data = try WalletKeychain.read(profile.connectionAccount) { settings = try JSONDecoder().decode(WalletConnection.self, from: data) }
            else { settings = WalletConnection() }
            fields["config"] = try await chainConfiguration(settings)
        }
        return fields
    }
    func prepareHardwareBoard(sourceID: String, amount: UInt64) async throws -> [String: Any] {
        try beginOperation(); defer { operations -= 1 }
        try await ensureConnected()
        let source = try await publicWalletFields(sourceID, withConnection: true)
        return try await call(["op": "ark_hardware_prepare", "amount_sat": amount, "source": source])
    }
    func hardwareReceiveAddress(walletID: String) async throws -> String {
        try beginOperation(); defer { operations -= 1 }
        _ = try await open()
        let source = try await publicWalletFields(walletID, withConnection: false)
        let result = try await call(["op": "public_wallet_address", "source": source])
        guard let address = result["address"] as? String else { throw WalletFailure(message: "Could not derive the hardware wallet address.") }
        return address
    }
    func connect(_ settings: WalletConnection) async throws {
        try beginOperation(); defer { operations -= 1 }
        try settings.validate()
        _ = try await open()
        let config = try await chainConfiguration(settings)
        connected = false
        var request: [String: Any] = ["op": "connect", "config": config]
        if try loadedCatalog().selected?.supportsArk == true, let rpc = settings.arkRPC {
            var arkConfig = config
            arkConfig["electrum_address"] = NSNull()
            arkConfig["esplora_address"] = NSNull()
            arkConfig["bitcoind_address"] = rpc.endpoint
            arkConfig["bitcoind_user"] = rpc.username
            arkConfig["bitcoind_pass"] = rpc.password
            arkConfig["socks5_proxy"] = rpc.useTor ? try await EmbeddedTor.shared.proxy(for: rpc.torProxy) : NSNull()
            request["ark_config"] = arkConfig
        }
        _ = try await call(request)
        try saveConnection(settings)
        connected = true
        if try loadedCatalog().selected?.supportsArk == true { _ = try await call(["op": "receive_listen", "enabled": foreground]) }
    }
    func setForeground(_ active: Bool) async {
        guard (try? beginOperation()) != nil else { return }; defer { operations -= 1 }
        foreground = active
        guard opened && connected, (try? loadedCatalog().selected?.supportsArk) == true else { return }
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
    func signMessage(address: String, message: String) async throws -> String {
        try beginOperation(); defer { operations -= 1 }
        _ = try await open()
        let result = try await call(["op": "sign_message_onchain", "address": address, "message": message])
        guard let signature = result["signature"] as? String else { throw WalletFailure(message: "No signature returned.") }
        return signature
    }
    func selectOnchainAccount(_ account: String) async throws {
        try beginOperation(); defer { operations -= 1 }
        _ = try await open()
        _ = try await call(["op": "select_onchain_account", "account": account])
    }
    func onchainOverview() async throws -> [String: Any] {
        try beginOperation(); defer { operations -= 1 }
        _ = try await open()
        return try await call(["op": "overview_onchain"])
    }
    func onchainAddresses(start: Int, change: Bool = false) async throws -> (entries: [[String: Any]], hasMore: Bool) {
        try beginOperation(); defer { operations -= 1 }
        _ = try await open()
        let result = try await call(["op": "addresses_onchain", "start": start, "change": change])
        guard let entries = result["addresses"] as? [[String: Any]] else { throw WalletFailure(message: "Invalid address list.") }
        return (entries, result["has_more"] as? Bool ?? false)
    }
    func coinjoin(_ op: String, walletID: String, fields: [String: Any] = [:]) async throws -> [String: Any] {
        try beginOperation(); defer { operations -= 1 }
        guard try loadedCatalog().selected?.id == walletID, try loadedCatalog().selected?.kind == .hot else {
            throw WalletFailure(message: "Open Coinjoin from the selected mobile wallet’s settings.")
        }
        if ["coinjoin_status", "coinjoin_address", "coinjoin_pool", "coinjoin_ack", "coinjoin_tick", "coinjoin_leave", "coinjoin_vote", "coinjoin_close"].contains(op) { _ = try await open() }
        else { try await ensureConnected() }
        var input = fields; input["op"] = op
        return try await call(input)
    }
    func operation(_ op: String, fields: [String: Any] = [:]) async throws -> [String: Any] {
        try beginOperation(); defer { operations -= 1 }
        if ["hardware_import", "hardware_cancel", "ark_hardware_import", "ark_hardware_cancel"].contains(op) { _ = try await open() }
        else { try await ensureConnected() }
        var input = fields; input["op"] = op
        return try await call(input)
    }
    func balances() async throws -> [String: Any] {
        try beginOperation(); defer { operations -= 1 }
        try await ensureConnected()
        return try await call(["op": "sync_ark"])
    }
    func synchronize() async throws -> WalletSnapshot {
        try beginOperation(); defer { operations -= 1 }
        let result = try await operation("sync")
        guard let tip = result["tip"] as? Int, let vtxos = result["vtxos"] as? [[String: Any]] else {
            throw WalletFailure(message: "Incomplete wallet sync.")
        }
        return WalletSnapshot(tip: tip, observedAt: Date(), estimatedBlockSeconds: 600,
            vtxos: try JSONDecoder().decode([VTXO].self, from: JSONSerialization.data(withJSONObject: vtxos)))
    }
    func refreshEligible() async throws { try beginOperation(); defer { operations -= 1 }; _ = try await call(["op": "refresh"]) }
    func activity() async throws -> [String: Any] {
        try beginOperation(); defer { operations -= 1 }
        try await ensureConnected()
        return try await call(["op": "activity"])
    }
    func quote(destination: String, amount: UInt64, onchain: Bool = false) async throws -> [String: Any] {
        try beginOperation(); defer { operations -= 1 }
        try await ensureConnected()
        return try await call(["op": onchain ? "quote_onchain" : "quote", "destination": destination, "amount_sat": amount])
    }
    func send(destination: String, amount: UInt64, total: UInt64, onchain: Bool = false) async throws -> [String: Any] {
        try beginOperation(); defer { operations -= 1 }
        return try await call(["op": onchain ? "send_onchain" : "send", "destination": destination, "amount_sat": amount, "total_sat": total])
    }
    func exportRecoveryArchive() async throws -> RecoveryArchive {
        try beginOperation(); defer { operations -= 1 }
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

        if let phrase = archive.seedPhrase {
            let derived = try await call(["op": "seed_derive", "phrase": phrase], seed: Data(repeating: 0, count: 64))
            guard derived["seed"] as? String == archive.seed.base64EncodedString() else { throw BackupError.invalidArchive }
        }
        provisioning = false
        _ = try await installProfile(WalletProfile(name: "Restored wallet", kind: .hot, network: archive.network),
            key: KeyRecord(seed: archive.seed, phrase: archive.seedPhrase, network: archive.network), archive: archive)
    }
}
