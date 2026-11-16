import SwiftUI
import UniformTypeIdentifiers
import PaperclipMobile

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BackupError.invalidArchive }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum BackupPage { case overview, save, check }

struct BackupView: View {
    let engine: (any WalletBackupEngine)?
    var restoreOnly = false
    var page = BackupPage.overview
    @EnvironmentObject var store: WalletStore
    @Environment(\.scenePhase) private var phase
    @State private var recoveryKey = ""
    @State private var confirmation = ""
    @State private var restoreKey = ""
    @State private var document: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var restoring = false
    @State private var busy = false
    @State private var pending: RecoveryArchive?
    @State private var status = ""
    @State private var checkingFile = false
    @State private var exportOwner: String?
    @State private var exportGeneration = UUID()
    @State private var savedAt: Date?
    @State private var checkedAt: Date?
    private func loadDates() {
        savedAt = UserDefaults.standard.object(forKey: "backup.saved." + store.walletID) as? Date
        checkedAt = UserDefaults.standard.object(forKey: "backup.checked." + store.walletID) as? Date
    }

    private var title: String {
        if restoreOnly { return "Restore backup" }
        switch page { case .overview: return "Backup & recovery"; case .save: return "Save backup"; case .check: return "Check backup" }
    }
    private var recoverySummary: some View {
        WalletSection("Your recovery plan") {
            LabeledContent("Last file saved", value: savedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not recorded")
            LabeledContent("Last restore check", value: checkedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not recorded")
            Text("Recorded on this device. Your storage provider manages cloud upload.").font(.caption).foregroundStyle(PaperclipTheme.muted)
        }
    }
    private var backupScope: some View {
        DisclosureGroup("What this backup includes") {
            Text("Wallet keys and the native Ark recovery database. App payment warnings, Bridge history and node connections stay on this device.")
            Text("Save a fresh backup after using Ark. A backup does not stop VTXO expiry; keep refreshing funds.")
        }.font(.caption).foregroundStyle(PaperclipTheme.muted)
    }
    private var actions: some View {
        WalletSection {
            NavigationLink { BackupView(engine: engine, page: .save) } label: {
                WalletNavigationRow("Save a backup", subtitle: "Encrypt your keys and Ark state", icon: "icloud.and.arrow.up")
            }.accessibilityIdentifier("backup-save")
            Divider()
            NavigationLink { BackupView(engine: engine, page: .check) } label: {
                WalletNavigationRow("Check a saved backup", subtitle: "Verify its file and recovery key", icon: "checkmark.shield")
            }.accessibilityIdentifier("backup-check")
            Divider()
            NavigationLink { BackupView(engine: engine, restoreOnly: true) } label: {
                WalletNavigationRow("Restore a backup", subtitle: "Add as a separate wallet", icon: "icloud.and.arrow.down")
            }.accessibilityIdentifier("backup-restore")
        }.buttonStyle(WalletNavigationButtonStyle())
    }
    @ViewBuilder private var content: some View {
        if restoreOnly {
            WalletSection("Restore as another wallet") {
                SecureField("Backup recovery key", text: $restoreKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Choose backup file…") { checkingFile = false; importing = true }
                    .disabled(engine == nil || restoreKey.isEmpty || busy)
                Text("Existing wallets are never replaced. Keep the original wallet offline while using its restored copy.").font(.caption)
            }
        } else {
            switch page {
            case .overview:
                WalletColumns { recoverySummary } secondary: { actions }
            case .save:
                WalletSection("Encrypted wallet backup") {
                    Text("Save your wallet keys and Ark state to Files. Keep the recovery key separately; Paperclip cannot recover a lost key.")
                    if engine == nil { Text("Create or restore a wallet before preparing a backup.").foregroundStyle(.orange) }
                    Button("Prepare encrypted backup") { Task { await prepare() } }.disabled(engine == nil || busy)
                    if !recoveryKey.isEmpty {
                        Text("Store this recovery key separately:").font(.headline)
                        Text(recoveryKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled).privacySensitive()
                        SecureField("Re-enter the saved recovery key", text: $confirmation).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Save encrypted file to Files…") { exporting = true }
                            .disabled(confirmation.trimmingCharacters(in: .whitespacesAndNewlines) != recoveryKey)
                    }
                    backupScope
                }
            case .check:
                WalletSection("Check a saved backup") {
                    SecureField("Backup recovery key", text: $restoreKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Choose file to check…") { checkingFile = true; importing = true }.disabled(engine == nil || restoreKey.isEmpty || busy)
                    Text("Verifies the file and tests restoration without changing your wallets or moving funds.").font(.caption)
                }
            }
        }
        if !status.isEmpty { WalletSection { Text(status) } }
    }
    var body: some View {
        ScrollView { VStack(spacing: 20) { content }
            .walletPageContent(maxWidth: page == .overview && !restoreOnly ? 1120 : 680).textFieldStyle(WalletInputStyle())
        }.navigationTitle(title).walletPageBackground()
            .fileExporter(isPresented: $exporting, document: document, contentType: .data,
                defaultFilename: "Paperclip-\(Date().formatted(.iso8601.year().month().day())).pcbackup") { result in
                switch result {
                case .success:
                    if let exportOwner { UserDefaults.standard.set(Date(), forKey: "backup.saved." + exportOwner) }
                    loadDates()
                    status = "Encrypted file saved to your selected location. Cloud upload completion is managed by Files."
                case .failure: status = "Backup was not saved. Try again; keep your recovery key."
                }
                clearExport()
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                let key = restoreKey
                restoreKey = ""
                Task { await loadBackup(result, key: key) }
            }
            .confirmationDialog("Restore this wallet?", isPresented: $restoring) {
                Button("Restore as a new wallet") { Task { await restore() } }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text("Backup network: \(pending?.network ?? "unknown"). The native engine will validate recovery state before importing.")
            }
            .onAppear { loadDates() }
            .onChange(of: store.walletID) { _, _ in clearExport(); restoreKey = ""; pending = nil; status = ""; loadDates() }
            .onChange(of: phase) { _, phase in
                if phase == .background { clearExport(); restoreKey = ""; pending = nil; restoring = false }
            }
    }
    @MainActor private func loadBackup(_ result: Result<URL, Error>, key: String) async {
        busy = true; defer { busy = false }
        let owner = store.walletID, checkOnly = checkingFile
        do {
            let url = try result.get()
            let archive = try await Task.detached {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: EncryptedBackup.maximumBytes + 1) ?? Data()
                return try EncryptedBackup.open(data, recoveryKey: key)
            }.value
            guard phase == .active, owner == store.walletID else { return }
            if checkOnly {
                guard let engine else { throw BackupError.unsupportedFormat }
                let matches = try await engine.verifyRecoveryArchive(archive)
                guard phase == .active, owner == store.walletID else { return }
                if matches { UserDefaults.standard.set(Date(), forKey: "backup.checked." + owner); loadDates() }
                status = matches ? "Restore check passed for this wallet. Backup created " + archive.createdAt.formatted(date: .abbreviated, time: .shortened) + ". Recent payments may need a newer backup." : "Restore check passed, but this backup belongs to another wallet. No wallet was changed."
            } else { pending = archive; restoring = true }
        } catch { status = "Could not open backup. Check the file and recovery key. No wallet was changed." }
    }
    private func prepare() async {
        guard let engine else { return }
        busy = true; defer { busy = false }
        let owner = store.walletID, ticket = exportGeneration
        do {
            let archive = try await engine.exportRecoveryArchive()
            guard phase == .active, owner == store.walletID, ticket == exportGeneration else { return }
            exportOwner = owner
            let key = EncryptedBackup.generateRecoveryKey()
            document = BackupDocument(data: try EncryptedBackup.seal(archive, recoveryKey: key))
            recoveryKey = key; confirmation = ""
        } catch {
            guard ticket == exportGeneration else { return }
            clearExport(); status = "Could not create an encrypted backup. No file was exported."
        }
    }
    private func restore() async {
        guard let engine, let archive = pending else { return }
        busy = true; defer { busy = false; pending = nil }
        do {
            try await engine.restoreIntoEmptyWallet(archive)
            await store.load()
            status = "Recovery data imported. Synchronize with the server before spending."
        } catch { status = "Restore failed or an existing wallet prevented import. Check the native wallet status." }
    }
    private func clearExport() {
        exportGeneration = UUID()
        recoveryKey = ""; confirmation = ""; document = nil; exporting = false; exportOwner = nil
    }
}
