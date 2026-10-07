import SwiftUI
import PaperclipMobile

struct WalletPickerView: View {
    @EnvironmentObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var renamed: WalletProfile?
    @State private var name = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletBrand()
                Text("Your wallets, together.").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(store.profiles) { profile in
                    WalletCard {
                        Button {
                            store.run { try await store.selectWallet(profile); dismiss() }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: profile.kind.icon).font(.title2).foregroundStyle(PaperclipTheme.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name).font(.headline)
                                    Text(profile.kind.title + (profile.network == "xbt-regtest" ? " · Regtest" : " · XBT"))
                                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                                }
                                Spacer()
                                Image(systemName: store.walletID == profile.id ? "checkmark.circle.fill" : "chevron.right").foregroundStyle(PaperclipTheme.orange)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button("Rename") { name = profile.name; renamed = profile }.font(.caption)
                    }
                }
                NavigationLink { AddWalletView() } label: {
                    WalletCard { WalletNavigationRow("Add a wallet", subtitle: "Create, import, connect, or watch", icon: "plus.circle") }
                }.buttonStyle(.plain)
                Text("Each wallet has separate keys, activity, and connection settings. Open each mobile wallet regularly to refresh its Ark funds. Switching cancels an unfinished QR signing request.")
                    .font(.caption).foregroundStyle(PaperclipTheme.muted)
                if store.busy { ProgressView() }
                if !store.message.isEmpty { Text(store.message).font(.caption).foregroundStyle(PaperclipTheme.muted) }
            }.padding(22)
        }.background(PaperclipTheme.navy).navigationTitle("Wallets").navigationBarTitleDisplayMode(.inline)
            .disabled(store.busy)
            .toolbar { Button("Done") { dismiss() } }
            .alert("Wallet name", isPresented: Binding(get: { renamed != nil }, set: { if !$0 { renamed = nil } })) {
                TextField("Name", text: $name)
                Button("Save") {
                    guard let profile = renamed else { return }
                    store.run { try await store.engine.rename(id: profile.id, name: name); await store.load() }
                    renamed = nil
                }
                Button("Cancel", role: .cancel) { renamed = nil }
            }
    }
}

struct AddWalletView: View {
    var publicOnly = false
    @EnvironmentObject var store: WalletStore
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            Text("Choose where your keys live.").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
            if !publicOnly {
                NavigationLink { SetupView(adding: true) } label: {
                    WalletCard { WalletNavigationRow("Mobile wallet", subtitle: "Create or import seed words · on-chain and Ark", icon: "wallet.pass") }
                }.buttonStyle(.plain)
            }
            NavigationLink { PublicWalletImportView(hardware: true) } label: {
                WalletCard { WalletNavigationRow("QR hardware wallet", subtitle: "Pair Krux, SeedSigner, or a compatible QR signer", icon: "qrcode") }
            }.buttonStyle(.plain)
            NavigationLink { PublicWalletImportView(hardware: false) } label: {
                WalletCard { WalletNavigationRow("Watch-only wallet", subtitle: "Monitor an account XPUB or public descriptor", icon: "eye") }
            }.buttonStyle(.plain)
            if !publicOnly {
                NavigationLink { BackupView(engine: store.engine, restoreOnly: true) } label: {
                    WalletCard { WalletNavigationRow("Restore encrypted backup", subtitle: "Add a saved mobile wallet without replacing others", icon: "icloud.and.arrow.down") }
                }.buttonStyle(.plain)
            }
            Text("Hardware and watch-only wallets are on-chain wallets. Their private keys are never imported into Paperclip.").font(.caption).foregroundStyle(PaperclipTheme.muted)
        }.padding(22) }.background(PaperclipTheme.navy).navigationTitle("Add wallet").navigationBarTitleDisplayMode(.inline)
    }
}

struct PublicWalletImportView: View {
    let hardware: Bool
    @EnvironmentObject var store: WalletStore
    @State private var name = ""
    @State private var value = ""
    @State private var script = "segwit"
    @State private var origin = ""
    @State private var network = "xbt-mainnet"
    @State private var connection: WalletConnection?
    @State private var scanning = false
    @State private var collector = SigningQRCollector()
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection {
                Label(hardware ? "Pair your hardware wallet" : "Keep an eye on your XBT", systemImage: hardware ? "qrcode" : "eye").font(.title2.bold())
                Text(hardware ? "Export an account public key or descriptor from your BLAKE2b Krux or SeedSigner. You’ll confirm and sign payments on the device." : "Import an account public key to see its balance, addresses, and transactions. This wallet cannot sign payments.").foregroundStyle(PaperclipTheme.muted)
            }
            WalletSection("Wallet") {
                TextField("Wallet name", text: $name)
                Picker("Network", selection: $network) { Text("XBT mainnet").tag("xbt-mainnet"); Text("Regtest").tag("xbt-regtest") }
                NavigationLink("Connection settings") { ConnectionsView(isSetup: true, onSave: { connection = $0 }, initialSettings: connection, onchainOnly: true) }
                Button { collector = SigningQRCollector(); scanning = true } label: { Label("Scan public wallet QR", systemImage: "qrcode.viewfinder") }.buttonStyle(.bordered)
                TextField("Account XPUB or public descriptor", text: $value, axis: .vertical).lineLimit(3...6)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !value.contains("(") {
                    Picker("Address type", selection: $script) {
                        Text("Native SegWit · BIP84").tag("segwit")
                        Text("Taproot · BIP86").tag("taproot")
                        Text("Nested SegWit · BIP49").tag("nested")
                        Text("Legacy · BIP44").tag("legacy")
                    }
                    if hardware && !value.hasPrefix("[") {
                        TextField("Origin, e.g. a1b2c3d4/84h/0h/0h", text: $origin).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Copy the master fingerprint and account derivation path from your signer. A descriptor or [fingerprint/path] key includes these already.").font(.caption)
                    }
                }
                Text("Use the same address type as the exporting wallet. Compare Paperclip’s first receive address with the device before funding it. Single-key wallets are supported; choose plain QR or BBQr when exporting. On SeedSigner, choose Specter to export the account key. Signed PSBTs support animated UR automatically.")
                    .font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
            Button(hardware ? "Add hardware wallet" : "Add watch-only wallet") {
                store.run {
                    _ = try await store.engine.addPublicWallet(name: name, value: value, script: script, origin: origin, network: network, hardware: hardware, connection: connection)
                    await store.load()
                }
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(value.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
            if store.busy { ProgressView() }
            Text(store.message).font(.caption).foregroundStyle(PaperclipTheme.muted)
        }.padding(22).textFieldStyle(WalletInputStyle()) }.background(PaperclipTheme.navy)
            .navigationTitle(hardware ? "Hardware wallet" : "Watch-only wallet").navigationBarTitleDisplayMode(.inline)
            .task { if name.isEmpty { name = hardware ? "Hardware wallet" : "Watch-only wallet" }; network = store.network }
            .fullScreenCover(isPresented: $scanning) {
                QRScannerView(title: "Scan public wallet", instruction: "Show the public key or descriptor QR from your wallet. Never scan seed words here.") { frame in
                    do {
                        guard let data = try collector.accept(frame, publicWallet: true) else { return (false, "Read \(collector.received) of \(collector.total) frames") }
                        guard let text = String(data: data, encoding: .utf8), text.utf8.count <= 4096 else { throw SigningQRError.invalid }
                        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let descriptor = object["descriptor"] as? String { value = descriptor }
                        else { value = text }
                        return (true, "Public wallet scanned")
                    } catch { return (false, error.localizedDescription) }
                }
            }
    }
}

struct WalletSendView: View {
    @EnvironmentObject var store: WalletStore
    var body: some View {
        if store.isHardware { HardwareSendView() }
        else if store.isWatchOnly { ContentUnavailableView("Watch-only wallet", systemImage: "eye", description: Text("Payments must be signed from the wallet that holds these keys.")) }
        else { SendView() }
    }
}
