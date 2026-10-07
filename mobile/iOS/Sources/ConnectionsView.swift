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
        Form {
            Section("Connection routing") {
                Toggle("On-chain Tor", isOn: $settings.useTor)
                    .accessibilityIdentifier("onchain-tor")
                if settings.useTor {
                    TorProxyPicker(selection: $settings.torProxy)
                }
                Toggle("Separate Ark RPC connection", isOn: $separateRPC)
                    .accessibilityIdentifier("separate-ark-rpc")
                Toggle("Ark Tor", isOn: Binding(
                    get: { separateRPC ? arkRPC.useTor : settings.useTor },
                    set: { if separateRPC { arkRPC.useTor = $0 } }
                ))
                    .disabled(!separateRPC)
                    .accessibilityIdentifier("ark-tor")
                if separateRPC {
                    if arkRPC.useTor {
                        TorProxyPicker(selection: $arkRPC.torProxy)
                    }
                    Text("Ark RPC and the Ark server use the Ark Tor setting independently of on-chain. Configure the RPC endpoint below.").font(.caption)
                } else {
                    Text("Ark shares the on-chain backend and Tor setting. Enable a separate Ark RPC connection to set its Tor route independently.").font(.caption)
                }
                if settings.useTor || (separateRPC && arkRPC.useTor) {
                    Text("Built-in Tor starts automatically when connecting. Keep Paperclip open while Tor connects. Connection failures never fall back to a direct connection.").font(.caption)
                }
            }
            Section("On-chain") {
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
            }
            Section("Ark") {
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
            }
            Section {
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
            }
        }.navigationTitle("Connections").scrollContentBackground(.hidden).background(PaperclipTheme.navy)
            .task { do { if let saved = try await store.engine.savedConnection() { settings = saved; separateRPC = saved.arkRPC != nil; arkRPC = saved.arkRPC ?? ArkRPCConnection() } } catch { store.message = error.localizedDescription } }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: WalletStore
    @EnvironmentObject var maintenance: Maintenance
    @AppStorage("automaticRefresh") private var automatic = true
    @AppStorage("walletLock") private var walletLock = true
    var body: some View {
        ScrollView {
          VStack(spacing: 20) {
            WalletSection { WalletBrand().padding(.vertical, 10) }
            WalletSection("Your wallet") {
                NavigationLink("On-chain addresses") { OnchainAddressesView() }
                NavigationLink("Connections") { ConnectionsView() }
                NavigationLink("Encrypted iCloud backup & restore") { BackupView(engine: store.engine) }
                Toggle("Require device authentication", isOn: $walletLock)
                Text("Keys use device-only Keychain storage. Background Ark refresh can access keys after the first device unlock.").font(.caption)
                LabeledContent("On-chain signing", value: "Unified sighash · 0x21")
            }
            WalletSection("Ark maintenance") {
                Toggle("Attempt automatic refresh", isOn: $automatic)
                Text("iOS controls background time. Open Paperclip regularly so Ark transactions can complete before expiry.").font(.caption)
                Button("Check and refresh") { Task { await maintenance.update(automatic: true) } }.disabled(maintenance.busy)
                Text(maintenance.message).font(.caption)
                Button("Enable expiry reminders") { Task { await maintenance.enableNotifications() } }
                Text(maintenance.notificationStatus).font(.caption)
            }
            WalletSection("Recovery") { NavigationLink("Ark recovery & emergency exit") { ArkToolsView() } }
          }.padding(22)
        }.navigationTitle("Settings").scrollContentBackground(.hidden).background(PaperclipTheme.navy)
    }
}
