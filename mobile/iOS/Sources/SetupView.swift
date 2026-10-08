import SwiftUI
import PaperclipMobile

struct SetupView: View {
    var adding = false
    @State private var connection: WalletConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var walletName = "My Paperclip wallet"
    @EnvironmentObject var store: WalletStore
    @Environment(\.scenePhase) private var phase
    @State private var phrase = ""
    @State private var confirmation = ""
    @State private var verifying = false
    @State private var importing = false
    @State private var importedPhrase = ""
    @State private var setupMessage = ""
    @State private var network = "xbt-mainnet"
    var body: some View {
        Group {
            if adding { setupContent }
            else { NavigationStack { setupContent } }
        }
    }
    private var setupContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    WalletBrand()
                    Text(verifying ? "Verify your seed" : (!phrase.isEmpty ? "Back up your wallet" : "Your XBT starts here")).font(.title.bold())
                    Text("On-chain · Lightning · Ark").foregroundStyle(PaperclipTheme.muted)
                    if verifying {
                        WalletCard {
                            Text("Enter all 24 words in order from your written copy. The phrase stays hidden during verification.")
                            TextEditor(text: $confirmation).frame(minHeight: 130).privacySensitive().accessibilityIdentifier("seed-confirmation")
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Verify and create wallet") { create(phrase, confirmation: confirmation) }
                                .buttonStyle(.borderedProminent).disabled(!SeedVerification.matches(phrase: phrase, confirmation: confirmation))
                                .accessibilityIdentifier("verify-seed")
                            Button("Show words again") { verifying = false; confirmation = "" }
                        }
                    } else if !phrase.isEmpty {
                        WalletCard {
                            Label("Write down these 24 words", systemImage: "pencil.and.list.clipboard").font(.headline)
                            Text("Keep the words offline and in this order. Anyone with these words can spend your XBT.").font(.subheadline)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                                ForEach(Array(phrase.split(separator: " ").enumerated()), id: \.offset) { index, word in
                                    HStack { Text(String(index + 1)).foregroundStyle(.secondary).frame(width: 24); Text(String(word)).fontWeight(.medium) }
                                        .font(.system(.body, design: .monospaced))
                                }
                            }.privacySensitive().accessibilityIdentifier("seed-words")
                            Button("I wrote down every word") { verifying = true }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        WalletSection("Mobile wallet") {
                            TextField("Wallet name", text: $walletName).textFieldStyle(WalletInputStyle())
                            Text("Create a wallet with keys stored securely on this iPhone. We’ll guide you through writing down and verifying your seed.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                            Button { store.run { phrase = try await store.engine.generatePhrase() } } label: {
                                Label("Create a wallet", systemImage: "plus").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("create-wallet")
                        }
                        WalletSection {
                            Button { importing = true } label: {
                                WalletNavigationRow("Import seed words", subtitle: "Restore with a 12- or 24-word phrase", icon: "key")
                            }.buttonStyle(.plain)
                            Divider()
                            NavigationLink { BackupView(engine: store.engine, restoreOnly: true) } label: {
                                WalletNavigationRow("Restore a backup", subtitle: "Recover an encrypted wallet and Ark data", icon: "icloud.and.arrow.down")
                            }.buttonStyle(.plain)
                            if !adding {
                                Divider()
                                NavigationLink { AddWalletView(publicOnly: true) } label: {
                                    WalletNavigationRow("Connect another wallet", subtitle: "QR hardware wallet or watch-only account", icon: "qrcode")
                                }.buttonStyle(.plain)
                            }
                        }
                        WalletSection {
                            DisclosureGroup("Network & connection") {
                                Picker("Network", selection: $network) { Text("XBT mainnet").tag("xbt-mainnet"); Text("Regtest").tag("xbt-regtest") }
                                NavigationLink { ConnectionsView(isSetup: true, onSave: { connection = $0 }, initialSettings: connection) } label: {
                                    WalletNavigationRow("Connection settings", subtitle: "Choose a server and Tor route before setup", icon: "network")
                                }.buttonStyle(.plain).accessibilityIdentifier("setup-connections")
                            }
                            if !adding {
                                DisclosureGroup("Already restored on this device?") {
                                    Button("Open restored wallet") { Task { await store.load() } }
                                }
                            }
                        }
                    }
                    Text("Ark recovery can require more than seed words. Save an encrypted full-wallet backup after setup and after changes to your Ark wallet.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                    if store.busy { ProgressView() }
                    if !setupMessage.isEmpty { Text(setupMessage).font(.caption).foregroundStyle(PaperclipTheme.orange) }
                }.padding(24)
            }.background(PaperclipTheme.navy).disabled(store.busy)
                .navigationTitle(verifying ? "Verify seed" : (!phrase.isEmpty ? "Back up seed" : "Mobile wallet"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(PaperclipTheme.navy, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .onChange(of: store.message) { _, message in setupMessage = message }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if !phrase.isEmpty {
                            Button {
                                confirmation = ""
                                if verifying { verifying = false } else { phrase = "" }
                            } label: { Label("Back", systemImage: "chevron.left") }
                            .disabled(store.busy).accessibilityIdentifier("setup-back")
                        }
                    }
                }
                .sheet(isPresented: $importing) {
                    NavigationStack {
                        ScrollView { VStack(spacing: 20) {
                            WalletSection("Connection") {
                                NavigationLink("Connection settings") { ConnectionsView(isSetup: true, onSave: { connection = $0 }, initialSettings: connection) }
                                    .accessibilityIdentifier("import-connections")
                                Text("Choose your Electrum server and Tor settings before importing.").font(.caption)
                            }
                            WalletSection("Import your seed") {
                                Text("Enter 12 or 24 BIP39 words. Seed import scans on-chain history and attempts Ark mailbox recovery. A full Ark backup gives more complete recovery for pending operations.")
                                TextEditor(text: $importedPhrase).frame(minHeight: 150).privacySensitive()
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("import-seed")
                                Picker("Network", selection: $network) { Text("XBT mainnet").tag("xbt-mainnet"); Text("Regtest").tag("xbt-regtest") }
                                Text("Seeds with a separate BIP39 passphrase are not supported in this build.").font(.caption)
                                Button("Import wallet") {
                                    let normalized = importedPhrase.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                                    create(normalized, confirmation: normalized, recovery: true)
                                }.disabled(![12, 24].contains(importedPhrase.split(whereSeparator: \.isWhitespace).count) || store.busy)
                            }
                            Text(store.message).foregroundStyle(PaperclipTheme.orange)
                        }.padding(22) }.background(PaperclipTheme.navy.ignoresSafeArea()).navigationTitle("Import wallet").toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { importing = false; importedPhrase = "" } label: { Label("Back", systemImage: "chevron.left") }
                                    .disabled(store.busy).accessibilityIdentifier("import-back")
                            }
                        }
                    }
                }
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-ui-testing") { network = "xbt-regtest" }
                    #endif
                }
                .onChange(of: phase) { _, phase in
                    if phase == .background { phrase = ""; confirmation = ""; importedPhrase = ""; verifying = false; importing = false }
                }
    }
    private func create(_ phrase: String, confirmation: String, recovery: Bool = false) {
        store.run {
            if try await store.engine.savedConnection() == nil {
                try await store.engine.saveConnection(WalletConnection())
            }
            _ = try await store.engine.addHotWallet(name: walletName, phrase: phrase, confirmation: confirmation, network: network, connection: connection)
            if recovery, let profile = try await store.engine.selectedProfile() { UserDefaults.standard.set(true, forKey: "seedRecoveryRequired-" + profile.id) }
            self.phrase = ""; self.confirmation = ""; importedPhrase = ""; importing = false
            await store.load()
            if adding { dismiss() }
            store.message = recovery ? "Seed imported. Configure a connection, then run recovery in Ark tools." : "Seed verified. Configure your connection to start."
        }
    }
}
