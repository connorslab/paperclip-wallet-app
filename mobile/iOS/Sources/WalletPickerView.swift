import SwiftUI
import PaperclipMobile

struct WalletPickerView: View {
    @EnvironmentObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var removing: WalletProfile?
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
                        HStack {
                            Button("Rename") { name = profile.name; renamed = profile }
                            Spacer()
                            Button("Remove wallet", role: .destructive) { removing = profile }
                        }.font(.caption)
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
        }.background(WalletBackdrop()).navigationTitle("Wallets").navigationBarTitleDisplayMode(.inline)
            .disabled(store.busy)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } } }
            .sheet(item: $removing) { profile in
                NavigationStack { RemoveWalletView(profile: profile) }
            }
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
        }.padding(22) }.background(WalletBackdrop()).navigationTitle("Add wallet").navigationBarTitleDisplayMode(.inline)
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
    @State private var reviewing = false
    @State private var manual = false
    @State private var help = false
    private var hasExport: Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection {
                WalletBrand()
                Text(reviewing ? "Review your wallet" : (hardware ? "Connect your signer" : "Follow your wallet")).font(.title2.bold())
                Text(reviewing ? "Check the account details before adding this wallet." : (hardware ? "Scan your device’s public wallet export. Your keys stay on the hardware wallet; Paperclip prepares payments for you to sign." : "Scan a public wallet export to follow its balance and activity. Private keys stay in the original wallet.")).foregroundStyle(PaperclipTheme.muted)
                Label(reviewing ? "Step 2 of 2 · Account details" : "Step 1 of 2 · Public wallet export", systemImage: reviewing ? "checklist" : "qrcode").font(.caption.bold()).foregroundStyle(PaperclipTheme.orange)
            }
            if !reviewing {
                WalletSection {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 48)).foregroundStyle(PaperclipTheme.orange).frame(maxWidth: .infinity).padding(.vertical, 8)
                    Button { collector = SigningQRCollector(); scanning = true } label: {
                        Label("Scan wallet QR", systemImage: "camera").frame(maxWidth: .infinity)
                    }.modifier(GlassAction())
                    Text("Scan an account public key or descriptor, never seed words.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    DisclosureGroup("Paste an export instead", isExpanded: $manual) {
                        TextField("Account XPUB or public descriptor", text: $value, axis: .vertical).lineLimit(3...6)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
                    }
                    if hasExport {
                        Button("Continue to account details") { reviewing = true }.buttonStyle(WalletPrimaryButtonStyle()).controlSize(.large)
                    }
                }
                WalletSection {
                    DisclosureGroup("How to export from your device", isExpanded: $help) {
                        Text("Use a BLAKE2b-compatible Krux or SeedSigner with a single-key wallet.").font(.subheadline)
                        Text("Krux: export the account public key or descriptor as plain QR or BBQr.\n\nSeedSigner: choose Specter for the account-key export.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                        Text("When paying later, you’ll scan the payment on your signer, approve it there, then scan the signed transaction back into Paperclip. Animated UR is supported for signed PSBTs.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    }
                }
            } else {
                WalletSection("Public wallet export") {
                    Label("Export captured", systemImage: "qrcode").font(.headline)
                    DisclosureGroup("View public export") {
                        Text(value).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button("Scan or edit again") { reviewing = false; manual = true }
                }
                WalletSection("Account details") {
                    Text("Wallet name").font(.subheadline.bold())
                    TextField("Wallet name", text: $name)
                    if !value.contains("(") {
                        Picker("Address type", selection: $script) {
                            Text("Native SegWit · BIP84").tag("segwit")
                            Text("Taproot · BIP86").tag("taproot")
                            Text("Nested SegWit · BIP49").tag("nested")
                            Text("Legacy · BIP44").tag("legacy")
                        }
                        Text("Match the address type selected on the exporting wallet.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                        if hardware && !value.hasPrefix("[") {
                            Text("Key origin").font(.subheadline.bold())
                            TextField("a1b2c3d4/84h/0h/0h", text: $origin).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Text("Enter the master fingerprint and account derivation path shown on your signer. Descriptors and [fingerprint/path] keys already include them.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                        }
                    }
                }
                WalletSection {
                    Label("Compare before receiving", systemImage: "checkmark.shield").font(.headline)
                    Text("After adding the wallet, compare Paperclip’s first receive address with your device before sending funds to it.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    Button(hardware ? "Add hardware wallet" : "Add watch-only wallet") {
                        store.run {
                            _ = try await store.engine.addPublicWallet(name: name, value: value, script: script, origin: origin, network: network, hardware: hardware, connection: connection)
                            await store.load()
                        }
                    }.buttonStyle(WalletPrimaryButtonStyle()).controlSize(.large).disabled(!hasExport || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
                }
            }
            WalletSection {
                DisclosureGroup("Network & connection") {
                    Picker("Network", selection: $network) { Text("XBT mainnet").tag("xbt-mainnet"); Text("Regtest").tag("xbt-regtest") }
                    NavigationLink { ConnectionsView(isSetup: true, onSave: { connection = $0 }, initialSettings: connection, onchainOnly: true) } label: {
                        WalletNavigationRow("Connection settings", subtitle: "Choose your chain backend and Tor route", icon: "network")
                    }.buttonStyle(.plain)
                }
            }
            if store.busy { ProgressView("Adding wallet…") }
            if !store.message.isEmpty { Text(store.message).font(.caption).foregroundStyle(PaperclipTheme.muted).textSelection(.enabled) }
        }.padding(22).textFieldStyle(WalletInputStyle()) }.background(WalletBackdrop())
            .navigationTitle(hardware ? "Hardware wallet" : "Watch-only wallet").navigationBarTitleDisplayMode(.inline)
            .disabled(store.busy)
            .task { if name.isEmpty { name = hardware ? "Hardware wallet" : "Watch-only wallet" }; network = store.network }
            .fullScreenCover(isPresented: $scanning) {
                QRScannerView(title: "Scan public wallet", instruction: "Show the public key or descriptor QR from your wallet. Never scan seed words here.") { frame in
                    do {
                        guard let data = try collector.accept(frame, publicWallet: true) else { return (false, "Read \(collector.received) of \(collector.total) frames") }
                        guard let text = String(data: data, encoding: .utf8), text.utf8.count <= 4096 else { throw SigningQRError.invalid }
                        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let descriptor = object["descriptor"] as? String { value = descriptor }
                        else { value = text }
                        reviewing = true
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

struct RemoveWalletView: View {
    let profile: WalletProfile
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledgement = false
    @State private var confirmation = ""
    @State private var confirming = false
    private var ready: Bool { acknowledgement && confirmation == "REMOVE " + profile.name }

    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection {
                Label("Remove from this device", systemImage: "trash").font(.title2.bold())
                Text(profile.name).font(.headline)
                Text(profile.kind.title).foregroundStyle(PaperclipTheme.muted)
                Text("This permanently deletes this wallet’s local data and connection settings. It does not move or return any funds. Other wallets, your Lightning node connection, and backups saved elsewhere remain unchanged.")
            }
            WalletSection("Before you continue") {
                if profile.supportsArk {
                    Text("Both Taproot and SegWit accounts, Coinjoin data, and Ark recovery data belong to this wallet and will be removed.")
                    Text("Finish pending payments, rounds, and exits first. Save your seed words and a current encrypted full-wallet backup outside this app. Seed words alone may not recover all Ark funds or pending Coinjoin state.")
                    Toggle("I have verified my seed backup and saved a current encrypted wallet backup outside this app.", isOn: $acknowledgement)
                } else {
                    Text("Your hardware device and its keys are not erased. Keep your public descriptor or account export so you can add this wallet again.")
                    Toggle("I have saved the public wallet export needed to add this wallet again.", isOn: $acknowledgement)
                }
                Text("Paperclip cannot verify your backup. Without the required recovery data, you may lose access to funds.")
                    .font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
            WalletSection("Confirm removal") {
                Text("Type exactly:").font(.subheadline)
                Text("REMOVE " + profile.name).font(.callout.monospaced()).textSelection(.enabled)
                TextField("Confirmation", text: $confirmation).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Remove wallet from this device", role: .destructive) { confirming = true }
                    .buttonStyle(.bordered).disabled(!ready || store.busy)
                Text("Device authentication is required, even if app locking is disabled.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                if store.busy { ProgressView() }
                if !store.message.isEmpty { Text(store.message).font(.caption) }
            }
        }.padding(22).textFieldStyle(WalletInputStyle()).disabled(store.busy) }
        .background(WalletBackdrop()).navigationTitle("Remove wallet").navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(store.busy)
        .toolbar { Button("Cancel") { dismiss() }.disabled(store.busy) }
        .alert("Permanently remove “\(profile.name)” from this device?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { }
            Button("Remove wallet", role: .destructive) {
                guard ready else { return }
                store.run {
                    try await store.engine.removeWallet(profile, confirmation: confirmation, backupAcknowledged: acknowledgement)
                    await Maintenance.shared.forgetWallet(profile.id)
                    await store.load()
                    dismiss()
                }
            }
        } message: { Text("There is no undo. Restoring requires your saved recovery data. No funds will be transferred.") }
    }
}
