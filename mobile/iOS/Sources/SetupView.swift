import SwiftUI
import PaperclipMobile

struct SetupView: View {
    @EnvironmentObject var store: WalletStore
    @Environment(\.scenePhase) private var phase
    @State private var phrase = ""
    @State private var confirmation = ""
    @State private var verifying = false
    @State private var importing = false
    @State private var importedPhrase = ""
    @State private var network = "xbt-mainnet"
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    WalletBrand()
                    Text(verifying ? "Verify your seed." : "One wallet.\nThree ways to pay.").font(.largeTitle.bold())
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
                        WalletCard {
                            Label("Your keys stay with you", systemImage: "key.fill").font(.headline)
                            Text("Create a seed, write it down, and verify it. Your seed and Ark recovery data use protected device storage.").foregroundStyle(PaperclipTheme.muted)
                            Picker("Network", selection: $network) { Text("XBT mainnet").tag("xbt-mainnet"); Text("Regtest").tag("xbt-regtest") }
                            NavigationLink("Connection settings") { ConnectionsView(isSetup: true) }
                                .accessibilityIdentifier("setup-connections")
                            Button("Create a wallet") { store.run { phrase = try await store.engine.generatePhrase() } }
                                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("create-wallet")
                            Button("Import 12 or 24 seed words") { importing = true }
                            NavigationLink("Restore an encrypted Ark backup") { BackupView(engine: store.engine, restoreOnly: true) }
                            Button("Open a restored wallet") { Task { await store.load() } }
                        }
                    }
                    Text("Ark recovery can require more than seed words. Save an encrypted full-wallet backup after setup and after changes to your Ark wallet.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                    if store.busy { ProgressView() }
                    Text(store.message).font(.caption).foregroundStyle(PaperclipTheme.orange)
                }.padding(24)
            }.background(PaperclipTheme.navy).disabled(store.busy)
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
                                NavigationLink("Connection settings") { ConnectionsView(isSetup: true) }
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
    }
    private func create(_ phrase: String, confirmation: String, recovery: Bool = false) {
        store.run {
            if try await store.engine.savedConnection() == nil {
                try await store.engine.saveConnection(WalletConnection())
            }
            _ = try await store.engine.create(phrase: phrase, confirmation: confirmation, network: network)
            if recovery { UserDefaults.standard.set(true, forKey: "seedRecoveryRequired") }
            self.phrase = ""; self.confirmation = ""; importedPhrase = ""; importing = false
            await store.load()
            store.message = recovery ? "Seed imported. Configure a connection, then run recovery in Ark tools." : "Seed verified. Configure your connection to start."
        }
    }
}
