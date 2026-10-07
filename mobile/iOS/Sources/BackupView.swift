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

struct BackupView: View {
    // A production adapter supplies this only after native wallet setup/recovery is implemented.
    let engine: (any WalletBackupEngine)?
    var restoreOnly = false
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

    var body: some View {
        ScrollView { VStack(spacing: 20) {
            if !restoreOnly {
            WalletSection("Encrypted iCloud Drive backup") {
                Text("Save an encrypted full-wallet backup to iCloud Drive using Files. Keep its recovery key somewhere separate. Paperclip cannot recover a lost key.")
                Text("Includes the seed and Ark recovery state. A backup does not stop VTXO expiry; keep refreshing funds.").font(.caption)
                if engine == nil { Text("Wallet backup is unavailable until a native wallet is connected. This preview does not export a placeholder backup.").foregroundStyle(.orange) }
                Button("Prepare encrypted backup") { Task { await prepare() } }.disabled(engine == nil || busy)
                if !recoveryKey.isEmpty {
                    Text("Record this recovery key separately from iCloud Drive:").font(.headline)
                    Text(recoveryKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled).privacySensitive()
                    SecureField("Re-enter the saved recovery key", text: $confirmation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save encrypted file to Files…") { exporting = true }
                        .disabled(confirmation.trimmingCharacters(in: .whitespacesAndNewlines) != recoveryKey)
                }
            }
            NavigationLink { BackupView(engine: engine, restoreOnly: true) } label: {
                WalletCard { WalletNavigationRow("Restore a backup", subtitle: "Add as a separate wallet", icon: "icloud.and.arrow.down") }
            }
            } else {
            WalletSection("Restore as another wallet") {
                SecureField("Backup recovery key", text: $restoreKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Choose backup from iCloud Drive…") { importing = true }
                    .disabled(engine == nil || restoreKey.isEmpty || busy)
                Text("Restoration never replaces an existing wallet. Avoid using the same restored wallet on two devices simultaneously.").font(.caption)
            }
            }
            if !status.isEmpty { WalletSection { Text(status) } }
        }.padding(22).textFieldStyle(WalletInputStyle()) }.navigationTitle(restoreOnly ? "Restore backup" : "Encrypted backup").background(PaperclipTheme.navy.ignoresSafeArea())
            .fileExporter(isPresented: $exporting, document: document, contentType: .data,
                defaultFilename: "Paperclip-\(Date().formatted(.iso8601.year().month().day())).pcbackup") { result in
                switch result {
                case .success: status = "Encrypted file saved to your selected location. iCloud upload completion is managed by Files."
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
            .onChange(of: phase) { _, phase in
                if phase == .background { clearExport(); restoreKey = ""; pending = nil; restoring = false }
            }
    }
    @MainActor private func loadBackup(_ result: Result<URL, Error>, key: String) async {
        busy = true; defer { busy = false }
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
            guard phase == .active else { return }
            pending = archive; restoring = true
        } catch { status = "Could not open backup. Check the file and recovery key. No wallet was changed." }
    }
    private func prepare() async {
        guard let engine else { return }
        busy = true; defer { busy = false }
        do {
            let archive = try await engine.exportRecoveryArchive()
            let key = EncryptedBackup.generateRecoveryKey()
            document = BackupDocument(data: try EncryptedBackup.seal(archive, recoveryKey: key))
            recoveryKey = key; confirmation = ""
        } catch { clearExport(); status = "Could not create a complete backup. No file was exported." }
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
    private func clearExport() { recoveryKey = ""; confirmation = ""; document = nil; exporting = false }
}
