import SwiftUI
import LocalAuthentication

struct MessageSigningView: View {
    @EnvironmentObject var store: WalletStore
    @State private var address = ""
    @State private var message = ""
    @State private var signature = ""
    @State private var status = ""
    @State private var working = false
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WalletSection("Sign a message") {
                    Text("Prove ownership of an on-chain Taproot address using BIP322-simple. Signing works offline and does not spend XBT.").font(.subheadline)
                    Text("Only sign messages you understand. A signature can authorize actions on another service.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                WalletSection("Address") {
                    TextField("Your on-chain address", text: $address, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Use a new receive address") {
                        working = true
                        Task {
                            defer { working = false }
                            do { address = try await store.engine.address(ark: false) }
                            catch { status = error.localizedDescription }
                        }
                    }
                }
                WalletSection("Exact message") {
                    TextEditor(text: $message).frame(minHeight: 150).scrollContentBackground(.hidden)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Text("\(message.utf8.count) / 4,096 UTF-8 bytes · spaces and line breaks matter").font(.caption)
                    Button("Authenticate and sign") { sign() }.modifier(GlassAction())
                        .disabled(address.isEmpty || message.utf8.count > 4096)
                }
                if !signature.isEmpty {
                    WalletSection("BIP322-simple signature") {
                        Text(signature).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy signature") { UIPasteboard.general.string = signature }
                        ShareLink("Share proof", item: "Address: \(address)\nFormat: BIP322-simple\nMessage:\n\(message)\nSignature: \(signature)")
                    }
                }
                if working || !status.isEmpty { WalletSection { if working { ProgressView() }; Text(status).font(.caption) } }
            }.walletPageContent().textFieldStyle(WalletInputStyle()).disabled(working)
        }.walletPageBackground().navigationTitle("Message signing")
            .onChange(of: address) { _, _ in signature = ""; status = "" }
            .onChange(of: message) { _, _ in signature = ""; status = "" }
    }
    private func sign() {
        let selected = address.trimmingCharacters(in: .whitespacesAndNewlines), exact = message
        working = true; signature = ""; status = ""
        Task {
            defer { working = false }
            do {
                let authenticated = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Sign the displayed message with your wallet address")
                guard authenticated else { return }
                let proof = try await store.engine.signMessage(address: selected, message: exact)
                guard selected == address.trimmingCharacters(in: .whitespacesAndNewlines), exact == message else { return }
                signature = proof
            } catch { status = error.localizedDescription }
        }
    }
}
