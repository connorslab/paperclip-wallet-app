import SwiftUI
import PaperclipMobile

struct ConnectionsView: View {
    @EnvironmentObject var store: WalletStore
    @State private var settings = WalletConnection()
    @State private var separateRPC = false
    @State private var arkRPC = ArkRPCConnection()
    var body: some View {
        Form {
            Section("On-chain") {
                Picker("Backend", selection: $settings.backend) { ForEach(ChainBackend.allCases, id: \.self) { Text($0.title).tag($0) } }
                TextField(settings.backend == .electrum ? "ssl://host:port" : "https://host", text: $settings.endpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if settings.backend == .electrum {
                    Button("Use Paperclip Pool (default)") { settings.endpoint = "ssl://pool.paperclippool.xyz:50002"; settings.certificateSHA256 = "" }
                    Button("Use Kilombino") { settings.endpoint = "ssl://fulcrum.kilombino.com:17717"; settings.certificateSHA256 = "" }
                    TextField("Certificate SHA256 (optional)", text: $settings.certificateSHA256)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("For self-signed TLS, obtain the certificate fingerprint from the server operator. A changed certificate will block the connection.").font(.caption)
                }
                if settings.backend == .rpc {
                    TextField("RPC username", text: $settings.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("RPC password", text: $settings.password)
                }
                Text("Use an XBT backend with BLAKE2b headers. Paperclip validates network and activation before use.").font(.caption)
            }
            Section("Ark") {
                TextField("Ark server", text: $settings.arkServer).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Paperclip default: ark.paperclippool.xyz").font(.caption)
                Button("Check saved backend for Ark") { store.run {
                    _ = try await store.engine.operation("ark_backend_check")
                    store.message = "Backend reports the required Ark relay capabilities and policy."
                } }.disabled(store.busy)
                Toggle("Use a separate RPC backend for Ark", isOn: $separateRPC)
                if separateRPC {
                    TextField("https://your-rpc-gateway", text: $arkRPC.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("RPC username", text: $arkRPC.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("RPC password", text: $arkRPC.password)
                }
                Text("Ark can use Electrum when the server exposes package relay and complete relay policy. RPC is optional for your own node. No public RPC endpoint is configured.").font(.caption)
            }
            Section("Tor") {
                Toggle("Route through Tor", isOn: $settings.useTor)
                if settings.useTor {
                    TextField("socks5h://host:port", text: $settings.torProxy).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Use a reachable Tor SOCKS proxy. This app does not start a Tor daemon. Onion names resolve through the proxy; connection failure does not fall back to a direct connection.").font(.caption)
                    if settings.backend == .rpc || separateRPC { Text("Knots RPC over Tor is not available in this build.").foregroundStyle(.orange) }
                }
            }
            Section {
                Button("Save and connect") { store.run { var connection = settings; connection.arkRPC = separateRPC ? arkRPC : nil; try await store.engine.connect(connection); try await store.synchronize() } }.disabled(store.busy)
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
        Form {
            Section { WalletBrand().padding(.vertical, 10).listRowBackground(PaperclipTheme.panel) }
            Section("Your wallet") {
                NavigationLink("Connections") { ConnectionsView() }
                NavigationLink("Encrypted iCloud backup & restore") { BackupView(engine: store.engine) }
                Toggle("Require device authentication", isOn: $walletLock)
                Text("Keys use device-only Keychain storage. Background Ark refresh can access keys after the first device unlock.").font(.caption)
                LabeledContent("On-chain signing", value: "Unified sighash · 0x21")
            }
            Section("Ark maintenance") {
                Toggle("Attempt automatic refresh", isOn: $automatic)
                Text("iOS controls background time. Open Paperclip regularly so Ark transactions can complete before expiry.").font(.caption)
                Button("Check and refresh") { Task { await maintenance.update(automatic: true) } }.disabled(maintenance.busy)
                Text(maintenance.message).font(.caption)
                Button("Enable expiry reminders") { Task { await maintenance.enableNotifications() } }
                Text(maintenance.notificationStatus).font(.caption)
            }
            Section("Recovery") { NavigationLink("Ark recovery & emergency exit") { ArkToolsView() } }
        }.navigationTitle("Settings").scrollContentBackground(.hidden).background(PaperclipTheme.navy)
    }
}
