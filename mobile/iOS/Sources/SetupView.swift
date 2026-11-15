import SwiftUI
import PaperclipMobile

struct SetupView: View {
    var adding = false
    @State private var connection: WalletConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var walletName = "Everyday wallet"
    @FocusState private var walletNameFocused: Bool
    @EnvironmentObject var store: WalletStore
    @Environment(\.scenePhase) private var phase
    @State private var phrase = ""
    @State private var generating = false
    @State private var seedWords = 24
    @State private var seedSource = "Secure system random"
    @State private var confirmationWords = Array(repeating: "", count: 24)
    @State private var showWordErrors = false
    @FocusState private var focusedWord: Int?
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
    private func confirmationField(_ index: Int) -> some View {
        let invalid = (!confirmationWords[index].isEmpty && !SeedWordEntry.isWord(confirmationWords[index]) && focusedWord != index)
            || (showWordErrors && SeedWordEntry.mismatches(phrase: phrase, entries: confirmationWords).contains(index))
        return HStack(spacing: 6) {
            Text("\(index + 1)").font(.caption.monospacedDigit())
                .foregroundStyle(invalid ? PaperclipTheme.orange : PaperclipTheme.muted)
                .frame(width: 20, alignment: .trailing)
            TextField("Word \(index + 1)", text: Binding(get: { confirmationWords[index] }, set: { updateWord($0, at: index) }))
                .textFieldStyle(.plain).font(.subheadline)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focusedWord, equals: index)
                .submitLabel(index + 1 == seedWords ? .done : .next)
                .onSubmit { focusedWord = index + 1 < seedWords ? index + 1 : nil }
                .accessibilityIdentifier("seed-word-\(index + 1)")
                .accessibilityLabel("Word \(index + 1)")
                .accessibilityHint(invalid ? "Check this word against your backup." : "")
        }
        .padding(.horizontal, 8).frame(minHeight: 48)
        .background(PaperclipTheme.muted.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(invalid ? PaperclipTheme.orange : PaperclipTheme.muted.opacity(0.2), lineWidth: 1))
        .accessibilitySortPriority(Double(seedWords - index))
    }
    private var welcoming: Bool { phrase.isEmpty && !verifying }
    private var walletNameValid: Bool {
        !walletName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && walletName.count <= 60
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            WalletBrand()
            WalletColumns {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your keys. Your bitcoin.")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("XBT, Lightning, and Ark. Start fresh or bring a wallet you already own.")
                        .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                WalletCard {
                    Label("Create a new wallet", systemImage: "sparkles")
                        .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("Your keys stay on this iPhone. We’ll help you make and verify a private backup before you begin.")
                        .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Wallet name").font(.subheadline.weight(.semibold))
                        TextField("Wallet name", text: $walletName)
                            .textFieldStyle(WalletInputStyle()).focused($walletNameFocused)
                            .submitLabel(.done).onSubmit { walletNameFocused = false }
                        Text(walletNameValid ? "A name to help you recognize this wallet. You can change it later." : "Enter a wallet name with 1–60 characters.")
                            .font(.caption).foregroundStyle(walletNameValid ? PaperclipTheme.muted : PaperclipTheme.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button { walletNameFocused = false; generating = true } label: {
                        HStack { Text("Create wallet"); Spacer(); Image(systemName: "arrow.right") }
                    }.buttonStyle(WalletPrimaryButtonStyle()).disabled(!walletNameValid).accessibilityIdentifier("create-wallet")
                }
            } secondary: {
                WalletSection("Already have a wallet?") {
                    Button { walletNameFocused = false; importing = true } label: {
                        WalletNavigationRow("Import seed words", subtitle: "Use your 12- or 24-word recovery phrase", icon: "key")
                    }.buttonStyle(.plain).accessibilityIdentifier("import-seed-words")
                    Divider()
                    NavigationLink { BackupView(engine: store.engine, restoreOnly: true).toolbar(.visible, for: .navigationBar) } label: {
                        WalletNavigationRow("Restore a backup", subtitle: "Recover a wallet and its Ark data", icon: "icloud.and.arrow.down")
                    }.buttonStyle(.plain)
                    if !adding {
                        Divider()
                        NavigationLink { AddWalletView(publicOnly: true).toolbar(.visible, for: .navigationBar) } label: {
                            WalletNavigationRow("Connect a wallet", subtitle: "Hardware wallet or watch-only account", icon: "qrcode")
                        }.buttonStyle(.plain)
                    }
                    Text("For the most complete Ark recovery, choose an encrypted full-wallet backup.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                WalletSection {
                    DisclosureGroup("Network & connection") {
                        Picker("Network", selection: $network) { Text("XBT mainnet").tag("xbt-mainnet"); Text("Regtest").tag("xbt-regtest") }
                        NavigationLink { ConnectionsView(isSetup: true, onSave: { connection = $0 }, initialSettings: connection).toolbar(.visible, for: .navigationBar) } label: {
                            WalletNavigationRow("Connection settings", subtitle: "Choose your server and Tor route", icon: "network")
                        }.buttonStyle(.plain).accessibilityIdentifier("setup-connections")
                    }
                    if !adding {
                        DisclosureGroup("Already restored on this device?") {
                            Button("Open restored wallet") { Task { await store.load() } }
                        }
                    }
                }
            }
        }
    }
    private var setupContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !welcoming { WalletFlowProgress(steps: ["Create", "Back up", "Confirm"], current: verifying ? 2 : 1) }
                    if verifying {
                        WalletCard {
                            Text("Confirm your words").font(.headline)
                            Text("Read down the left column, then down the right.")
                                .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                            Text("\(confirmationWords.filter { SeedWordEntry.isWord($0) }.count) of \(seedWords) words entered")
                                .font(.caption).foregroundStyle(PaperclipTheme.muted)
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(0..<2, id: \.self) { column in
                                    VStack(spacing: 10) {
                                        ForEach((column * seedWords / 2)..<((column + 1) * seedWords / 2), id: \.self) { index in
                                            confirmationField(index)
                                        }
                                    }.frame(maxWidth: .infinity)
                                        .accessibilityElement(children: .contain)
                                }
                            }.privacySensitive()
                            Button("Verify and create wallet") {
                                focusedWord = nil
                                showWordErrors = true
                                let entered = confirmationWords.map(SeedWordEntry.normalized).joined(separator: " ")
                                guard SeedVerification.matches(phrase: phrase, confirmation: entered) else { return }
                                create(phrase, confirmation: entered)
                            }
                                .buttonStyle(WalletPrimaryButtonStyle()).disabled(!confirmationWords.allSatisfy(SeedWordEntry.isWord))
                                .accessibilityIdentifier("verify-seed")
                            if showWordErrors && !SeedWordEntry.mismatches(phrase: phrase, entries: confirmationWords).isEmpty {
                                Text("Some words don’t match. Check the highlighted numbers above, or show your backup again.").font(.subheadline).foregroundStyle(PaperclipTheme.orange)
                            }
                            Button("Show words again") { focusedWord = nil; verifying = false; showWordErrors = false }

                        }
                    } else if !phrase.isEmpty {
                        WalletCard {
                            Label("Write down these \(seedWords) words", systemImage: "pencil.and.list.clipboard").font(.headline)
                            Text("\(seedWords == 12 ? 128 : 256)-bit BIP39 entropy · \(seedSource)").font(.caption).foregroundStyle(PaperclipTheme.muted)
                            Text("Keep the words offline and in this order. Anyone with these words can spend your XBT.").font(.subheadline)
                            Text("Read down the left column, then down the right.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                            let words = phrase.split(separator: " ")
                            let rows = (words.count + 1) / 2
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(0..<2, id: \.self) { column in
                                    VStack(alignment: .leading, spacing: 14) {
                                        ForEach((column * rows)..<min((column + 1) * rows, words.count), id: \.self) { index in
                                            HStack {
                                                Text(String(index + 1)).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                                                Text(String(words[index])).fontWeight(.medium)
                                            }
                                            .font(.system(.body, design: .monospaced))
                                            .accessibilityElement(children: .ignore)
                                            .accessibilityLabel("Word \(index + 1), \(words[index])")
                                            .accessibilitySortPriority(Double(words.count - index))
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityElement(children: .contain)
                                }
                            }.privacySensitive().accessibilityIdentifier("seed-words")
                            Button("I wrote down every word") { confirmationWords = Array(repeating: "", count: seedWords); showWordErrors = false; verifying = true }.buttonStyle(WalletPrimaryButtonStyle())
                        }
                    } else { welcomeContent }
                    if !welcoming {
                    Text("Ark recovery can require more than seed words. Save an encrypted full-wallet backup after setup and after changes to your Ark wallet.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                    }
                    if store.busy { ProgressView() }
                    if !setupMessage.isEmpty { Text(setupMessage).font(.caption).foregroundStyle(PaperclipTheme.orange) }
                }.walletPageContent(maxWidth: welcoming ? 1120 : 760)
            }.scrollDismissesKeyboard(.interactively).walletPageBackground().id(verifying).disabled(store.busy)
                .accessibilityHidden(phase != .active)
                .overlay { if phase != .active { PaperclipTheme.navy.ignoresSafeArea().overlay { Image(systemName: "lock.fill").font(.largeTitle) } } }
                .navigationTitle(verifying ? "Confirm backup" : (!phrase.isEmpty ? "Back up wallet" : adding ? "Add a wallet" : ""))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar(welcoming && !adding ? .hidden : .visible, for: .navigationBar)
                .onChange(of: store.message) { _, message in setupMessage = message }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        if verifying, let index = focusedWord {
                            ForEach(Array(SeedWordEntry.suggestions(confirmationWords[index]).prefix(3)), id: \.self) { word in
                                Button(word) {
                                    confirmationWords[index] = word
                                    focusedWord = index + 1 < seedWords ? index + 1 : nil
                                }
                            }
                            Spacer()
                            Button("Done") { focusedWord = nil }
                                .accessibilityIdentifier("seed-keyboard-done")
                        } else if walletNameFocused {
                            Spacer()
                            Button("Done") { walletNameFocused = false }.accessibilityIdentifier("wallet-name-done")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        if !phrase.isEmpty {
                            Button {
                                confirmationWords = Array(repeating: "", count: seedWords); focusedWord = nil
                                if verifying { verifying = false } else { phrase = "" }
                            } label: { Label("Back", systemImage: "chevron.left") }
                            .disabled(store.busy).accessibilityIdentifier("setup-back")
                        }
                    }
                }
                .sheet(isPresented: $generating) {
                    NavigationStack {
                        SeedGenerationView { entropy, words, source in
                            let generated = try await store.engine.generatePhrase(entropy: entropy)
                            guard phase == .active, generating else { throw WalletFailure(message: "Seed creation canceled. Start again while the app is active.") }
                            seedWords = words; seedSource = source; phrase = generated
                        }
                    }
                }
                .sheet(isPresented: $importing) {
                    NavigationStack {
                        ScrollView { VStack(spacing: 20) {
                            WalletSection("Connection") {
                                NavigationLink("Connection settings") { ConnectionsView(isSetup: true, onSave: { connection = $0 }, initialSettings: connection).toolbar(.visible, for: .navigationBar) }
                                    .accessibilityIdentifier("import-connections")
                                Text("Choose your Electrum server and Tor settings before importing.").font(.caption)
                            }
                            WalletSection("Import your seed") {
                                Text("Wallet name").font(.subheadline.weight(.semibold))
                                TextField("Wallet name", text: $walletName).textFieldStyle(WalletInputStyle())
                                if !walletNameValid { Text("Enter a wallet name with 1–60 characters.").font(.caption).foregroundStyle(PaperclipTheme.orange) }
                                Text("Enter 12 or 24 BIP39 words. Seed import scans on-chain history and attempts Ark mailbox recovery. A full Ark backup gives more complete recovery for pending operations.")
                                SeedImportFields(phrase: $importedPhrase)
                                Picker("Network", selection: $network) { Text("XBT mainnet").tag("xbt-mainnet"); Text("Regtest").tag("xbt-regtest") }
                                Text("Seeds with a separate BIP39 passphrase are not supported in this build.").font(.caption)
                                Button("Import wallet") {
                                    let normalized = importedPhrase.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                                    create(normalized, confirmation: normalized, recovery: true)
                                }.disabled(!walletNameValid || ![12, 24].contains(importedPhrase.split(whereSeparator: \.isWhitespace).count) || !importedPhrase.split(separator: " ").allSatisfy { SeedWordEntry.isWord(String($0)) } || store.busy)
                            }
                            Text(store.message).foregroundStyle(PaperclipTheme.orange)
                        }.walletPageContent() }.walletPageBackground().navigationTitle("Import wallet").toolbar {
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
                    if phase == .background { focusedWord = nil; importedPhrase = ""; importing = false; generating = false }
                    // Keep the draft in memory across lock/background, never on disk.
                    // An explicit back/cancel or process termination discards it.
                }
    }
    private func updateWord(_ value: String, at index: Int) {
        let pasted = SeedWordEntry.pastedWords(value)
        if pasted.count > 1 {
            guard pasted.count <= confirmationWords.count - index else {
                setupMessage = "Too many words for the remaining fields. Paste the full phrase into Word 1."; return
            }
            for (offset, word) in pasted.enumerated() { confirmationWords[index + offset] = word }
        } else { confirmationWords[index] = value.lowercased() }
        showWordErrors = false
    }
    private func create(_ phrase: String, confirmation: String, recovery: Bool = false) {
        store.run {
            if try await store.engine.savedConnection() == nil {
                try await store.engine.saveConnection(WalletConnection())
            }
            _ = try await store.engine.addHotWallet(name: walletName, phrase: phrase, confirmation: confirmation, network: network, connection: connection)
            if recovery, let profile = try await store.engine.selectedProfile() { UserDefaults.standard.set(true, forKey: "seedRecoveryRequired-" + profile.id) }
            self.phrase = ""; self.confirmationWords = Array(repeating: "", count: seedWords); importedPhrase = ""; importing = false
            await store.load()
            if adding { dismiss() }
            store.message = recovery ? "Seed imported. Configure a connection, then run recovery in Ark tools." : "Seed verified. Configure your connection to start."
        }
    }
}

// The import sheet uses the same compact, column-major entry as seed confirmation.
private struct SeedImportFields: View {
    @Binding var phrase: String
    @State private var count = 12
    @State private var words = Array(repeating: "", count: 24)
    @State private var message = ""
    @FocusState private var focus: Int?
    private func update(_ value: String, at index: Int) {
        let pasted = SeedWordEntry.pastedWords(value)
        if pasted.count > 1 {
            if index == 0 && [12, 24].contains(pasted.count) { count = pasted.count }
            guard pasted.count <= count - index else { phrase = ""; message = "Too many words for the selected phrase length."; return }
            for (offset, word) in pasted.enumerated() { words[index + offset] = word }
        } else { words[index] = value.lowercased() }
        message = ""
        phrase = words.prefix(count).allSatisfy(SeedWordEntry.isWord) ? words.prefix(count).map(SeedWordEntry.normalized).joined(separator: " ") : ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Seed length", selection: $count) {
                Text("12 words").tag(12); Text("24 words").tag(24)
            }.pickerStyle(.segmented)
                .onChange(of: count) { _, _ in focus = nil; phrase = words.prefix(count).allSatisfy(SeedWordEntry.isWord) ? words.prefix(count).map(SeedWordEntry.normalized).joined(separator: " ") : "" }
            Text("Read down the left column, then down the right. You can paste the full phrase into the first word.")
                .font(.caption).foregroundStyle(PaperclipTheme.muted)
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<2, id: \.self) { column in
                    VStack(spacing: 10) {
                        ForEach((column * count / 2)..<((column + 1) * count / 2), id: \.self) { index in
                            let invalid = !words[index].isEmpty && !SeedWordEntry.isWord(words[index]) && focus != index
                            HStack(spacing: 6) {
                                Text("\(index + 1)").font(.caption.monospacedDigit())
                                    .foregroundStyle(invalid ? PaperclipTheme.orange : PaperclipTheme.muted).frame(width: 20, alignment: .trailing)
                                TextField("Word \(index + 1)", text: Binding(get: { words[index] }, set: { update($0, at: index) }))
                                    .textFieldStyle(.plain).font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .focused($focus, equals: index).submitLabel(index + 1 == count ? .done : .next)
                                    .onSubmit { focus = index + 1 < count ? index + 1 : nil }
                                    .accessibilityIdentifier("import-word-\(index + 1)")
                                    .accessibilityLabel("Word \(index + 1)")
                            }.padding(.horizontal, 8).frame(minHeight: 48)
                                .background(PaperclipTheme.muted.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(invalid ? PaperclipTheme.orange : PaperclipTheme.muted.opacity(0.2)))
                                .accessibilitySortPriority(Double(count - index))
                        }
                    }.frame(maxWidth: .infinity).accessibilityElement(children: .contain)
                }
            }.privacySensitive()
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(PaperclipTheme.orange) }
        }.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if let index = focus {
                    ForEach(Array(SeedWordEntry.suggestions(words[index]).prefix(3)), id: \.self) { word in
                        Button(word) { update(word, at: index); focus = index + 1 < count ? index + 1 : nil }
                    }
                    Spacer()
                    Button("Done") { focus = nil }.accessibilityIdentifier("import-keyboard-done")
                }
            }
        }
    }
}
