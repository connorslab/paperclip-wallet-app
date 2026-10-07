import SwiftUI
import PaperclipMobile

struct ConnectionsView: View {
    @EnvironmentObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    var isSetup = false
    @State private var settings = WalletConnection()
    @State private var separateRPC = false
    @State private var arkRPC = ArkRPCConnection()
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletSection("Network connections") {
                    NavigationLink {
                        connectionPage("On-chain connection") { chainCard }
                    } label: { WalletNavigationRow("On-chain", subtitle: settings.backend.title + (settings.useTor ? " · Tor" : " · Direct"), icon: "link") }
                    NavigationLink {
                        connectionPage("Ark connection") { arkCard }
                    } label: { WalletNavigationRow("Ark", subtitle: separateRPC ? "Separate RPC connection" : "Shares on-chain backend", icon: "square.stack.3d.up") }
                    Text("Lightning node settings are on the Lightning tab.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                saveCard
            }.padding(22)
        }.navigationTitle("Connections").background(PaperclipTheme.navy.ignoresSafeArea())
            .task { do { if let saved = try await store.engine.savedConnection() { settings = saved; separateRPC = saved.arkRPC != nil; arkRPC = saved.arkRPC ?? ArkRPCConnection() } } catch { store.message = error.localizedDescription } }
    }
    private func connectionPage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView { VStack(spacing: 20) {
            content()
            if settings.useTor || (separateRPC && arkRPC.useTor) {
                Text("Built-in Tor starts when connecting. Keep Paperclip open while it connects. A Tor connection never falls back to a direct connection.").font(.caption)
            }
            saveCard
        }.padding(22).textFieldStyle(WalletInputStyle()).disabled(store.busy) }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline).background(PaperclipTheme.navy.ignoresSafeArea())
    }
    private var chainCard: some View { WalletSection("On-chain") {
                Toggle("Use Tor for on-chain", isOn: $settings.useTor).accessibilityIdentifier("onchain-tor")
                if settings.useTor { TorProxyPicker(selection: $settings.torProxy) }
                Picker("Backend", selection: $settings.backend) { ForEach(ChainBackend.allCases, id: \.self) { Text($0.title).tag($0) } }
                TextField(settings.backend == .electrum ? "tcp://host:port or ssl://host:port" : "http://host or https://host", text: $settings.endpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("chain-endpoint")
                if settings.backend == .electrum {
                    Text("Local Electrum: tcp://192.168.1.10:50001. For TLS use ssl://host:50002. Use your server's configured port.").font(.caption)
                    Button("Use Paperclip Pool (default)") { settings.endpoint = "ssl://pool.paperclippool.xyz:50002"; settings.certificateSHA256 = "" }
                    TextField("Certificate SHA256 (optional)", text: $settings.certificateSHA256)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("For self-signed TLS, obtain the certificate fingerprint from the server operator. A changed certificate will block the connection.").font(.caption)
                }
                if settings.backend == .rpc {
                    TextField("RPC username", text: $settings.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("RPC password", text: $settings.password)
                    if settings.endpoint.lowercased().hasPrefix("http://") {
                        Text("HTTP sends RPC credentials without encryption. Use it on a trusted local network.").font(.caption)
                    }
                }
                Text("Use an XBT backend with BLAKE2b headers. Paperclip validates network and activation before use.").font(.caption)
            } }
    private var arkCard: some View { WalletSection("Ark") {
                Toggle("Separate Ark RPC connection", isOn: $separateRPC).accessibilityIdentifier("separate-ark-rpc")
                if separateRPC {
                    Toggle("Use Tor for Ark", isOn: $arkRPC.useTor).accessibilityIdentifier("ark-tor")
                    if arkRPC.useTor { TorProxyPicker(selection: $arkRPC.torProxy) }
                } else { Text("Ark shares your on-chain backend and Tor setting.").font(.caption) }
                TextField("Ark server", text: $settings.arkServer).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Paperclip default: ark.paperclippool.xyz").font(.caption)
                if !isSetup { Button("Check saved backend for Ark") { store.run {
                    _ = try await store.engine.operation("ark_backend_check")
                    store.message = "Backend reports the required Ark relay capabilities and policy."
                } }.disabled(store.busy) }
                if separateRPC {
                    TextField("http://local-node:port or https://host", text: $arkRPC.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("RPC username", text: $arkRPC.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("RPC password", text: $arkRPC.password)
                    if arkRPC.endpoint.lowercased().hasPrefix("http://") {
                        Text("HTTP sends RPC credentials without encryption. Use it on a trusted local network.").font(.caption)
                    }
                }
                Text("Ark can use Electrum when the server exposes package relay and complete relay policy. RPC is optional for your own node. No public RPC endpoint is configured.").font(.caption)
            } }
    private var saveCard: some View { WalletSection {
                Button(isSetup ? "Save connection" : "Save and connect") { store.run {
                    var connection = settings
                    connection.arkRPC = separateRPC ? arkRPC : nil
                    if isSetup {
                        try await store.engine.saveConnection(connection)
                        store.message = "Connection saved for your wallet."
                        dismiss()
                    } else {
                        try await store.engine.connect(connection)
                        try await store.synchronize()
                    }
                } }.disabled(store.busy).accessibilityIdentifier("save-connection")
                if isSetup { Text("Save your server and Tor settings before creating or importing a wallet. Network access starts when you connect or run recovery.").font(.caption) }
                if store.busy { ProgressView() }
                Text(store.message).font(.caption)
            } }
}

struct SettingsView: View {
    @EnvironmentObject var store: WalletStore
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletSection { WalletBrand() }
                WalletSection("Preferences") {
                    NavigationLink { DisplaySettingsView() } label: { WalletNavigationRow("Appearance & units", subtitle: "Light, dark, sats, or XBT", icon: "circle.lefthalf.filled") }
                    NavigationLink { ConnectionsView() } label: { WalletNavigationRow("Connections", subtitle: "On-chain and Ark servers · Tor", icon: "network") }
                }
                WalletSection("Security & recovery") {
                    NavigationLink { SecuritySettingsView() } label: { WalletNavigationRow("Wallet security", subtitle: "Device authentication and protected storage", icon: "lock.shield") }.accessibilityIdentifier("settings-security")
                    NavigationLink { BackupView(engine: store.engine) } label: { WalletNavigationRow("Encrypted backup", subtitle: "Save your wallet and Ark recovery data", icon: "icloud.and.arrow.up") }
                    NavigationLink { ArkToolsView() } label: { WalletNavigationRow("Recovery", subtitle: "Seed recovery and emergency exits", icon: "arrow.counterclockwise") }
                }
                WalletSection("Wallet tools") {
                    NavigationLink { OnchainAddressesView() } label: { WalletNavigationRow("On-chain addresses", subtitle: "Receive and change addresses", icon: "list.bullet") }
                    NavigationLink { MessageSigningView() } label: { WalletNavigationRow("Sign a message", subtitle: "Prove ownership of an on-chain address", icon: "signature") }
                    NavigationLink { ArkMaintenanceView() } label: { WalletNavigationRow("Ark maintenance", subtitle: "Refresh funds and expiry reminders", icon: "arrow.triangle.2.circlepath") }
                }
            }.padding(22)
        }.navigationTitle("Settings").background(PaperclipTheme.navy.ignoresSafeArea())
    }
}

struct DisplaySettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection("Display") {
                LabeledContent("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }.labelsHidden()
                }
                LabeledContent("Bitcoin unit") {
                    Picker("Bitcoin unit", selection: $unit) {
                        ForEach(BitcoinUnit.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
                Text("1 XBT = 100,000,000 sats. Applies to balances, payments, fees, and activity.").font(.caption)
            }
        }.padding(22) }.navigationTitle("Appearance & units").background(PaperclipTheme.navy.ignoresSafeArea())
    }
}

struct SecuritySettingsView: View {
    @AppStorage("walletLock") private var walletLock = true
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection("Device protection") {
                Toggle("Require device authentication", isOn: $walletLock)
                Text("Keys use device-only Keychain storage. Background Ark refresh can access keys after the first device unlock.").font(.caption)
            }
            WalletSection("Transaction signing") {
                LabeledContent("On-chain signing", value: "Unified sighash · 0x21")
                Text("Message ownership proofs use BIP322-simple. They cannot spend wallet funds.").font(.caption)
            }
        }.padding(22) }.navigationTitle("Wallet security").background(PaperclipTheme.navy.ignoresSafeArea())
    }
}

struct ArkMaintenanceView: View {
    @EnvironmentObject var maintenance: Maintenance
    @AppStorage("automaticRefresh") private var automatic = true
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection("Ark maintenance") {
                Toggle("Attempt automatic refresh", isOn: $automatic)
                Text("iOS controls background time. Open Paperclip regularly so Ark transactions can complete before expiry.").font(.caption)
                Button("Check and refresh") { Task { await maintenance.update(automatic: true) } }.disabled(maintenance.busy)
                Text(maintenance.message).font(.caption)
                Button("Enable expiry reminders") { Task { await maintenance.enableNotifications() } }
                Text(maintenance.notificationStatus).font(.caption)
            }
        }.padding(22) }.navigationTitle("Ark maintenance").background(PaperclipTheme.navy.ignoresSafeArea())
    }
}
