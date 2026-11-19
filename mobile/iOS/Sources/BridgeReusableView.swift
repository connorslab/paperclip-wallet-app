import SwiftUI
import PaperclipMobile

struct BridgeReusableView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: WalletStore
    @ObservedObject private var model = BridgeReusableModel.shared
    @State private var destination = ""
    @State private var receiveXBT = true
    @State private var restoreKey = ""
    @State private var reviewing = false
    @State private var scanning = false
    @State private var revoking: ReusableBridgeRecord?
    @State private var selected: UUID?
    @State private var showKey = false
    @State private var localMessage = ""
    init(destination: String = "", receiveXBT: Bool = true) {
        _destination = State(initialValue: destination); _receiveXBT = State(initialValue: receiveXBT)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                WalletSection {
                    HStack {
                        Label("Reusable bridge offers", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                        Spacer()
                        Label(model.available == true ? "Live" : model.available == false ? "Paused" : "Status unknown", systemImage: model.available == true ? "checkmark.circle.fill" : model.available == false ? "pause.circle.fill" : "questionmark.circle")
                            .font(.caption.weight(.medium)).foregroundStyle(model.available == true ? Color.green : PaperclipTheme.muted)
                            .padding(.horizontal, 8).padding(.vertical, 5).background(.primary.opacity(0.05), in: Capsule())
                            .accessibilityHint("Reusable bridge availability, not payment status")
                    }
                    if !reviewing && selected == nil { Text("Receive across networks with one BOLT12 offer. Each payment uses the current exchange rate, fees and bridge limits.").font(.subheadline).foregroundStyle(PaperclipTheme.muted) }
                }
                if let row = model.records.first(where: { $0.id == selected }) {
                    WalletSection("Saved offer") {
                        if let binding = row.binding {
                            LabeledContent("Recipient receives", value: binding.direction.targetIsXBT ? "XBT" : "Spamcoin (BTC)")
                            LabeledContent("Sender pays", value: binding.direction.targetIsXBT ? "Spamcoin (BTC)" : "XBT")
                            if !binding.revoked && !row.revocationRequested {
                                ReceiveCode(value: binding.offer)
                                if !binding.direction.targetIsXBT {
                                    NavigationLink("Pay from my Lightning node") { LightningView(initialPayment: binding.offer) }.buttonStyle(WalletPrimaryButtonStyle())
                                    if store.hasWallet && store.supportsArk && !store.isHardware && !store.isWatchOnly && store.network == "xbt-mainnet" {
                                        NavigationLink("Pay from Ark") { SendView(onchain: false, initialDestination: binding.offer) }.buttonStyle(.bordered)
                                    }
                                }
                                Text(binding.direction.targetIsXBT ? "Share with a BTC wallet that supports BOLT12." : "Pay this XBT offer from Ark or your Lightning node using the normal send screen. Review the requested XBT amount there.").font(.caption)
                            } else { Text(binding.revoked ? "Revoked" : "Revocation not confirmed · sharing disabled") }
                        } else { Text("Registration not confirmed. Check status or retry this same saved request.") }
                        Button("Check status") { model.run { try await model.update(row, action: "lookup") } }
                        if row.binding == nil && row.destination != nil && !row.revocationRequested {
                            Button("Retry saved registration") { model.run { try await model.update(row, action: "register") } }
                        }
                        DisclosureGroup("Private recovery key", isExpanded: $showKey) {
                            Text("Keep this key private. It can restore or revoke the offer, but cannot spend funds or change its destination. Save it separately before removing the app.").font(.caption)
                            Button("Copy private management key") { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: row.token]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]) }
                        }
                        if row.binding?.revoked != true { Button("Revoke offer", role: .destructive) { revoking = row } }
                        Button("Back to offers") { selected = nil; showKey = false }
                    }
                } else {
                    WalletSection(reviewing ? "Review receiving wallet" : "Create an offer") {
                        if reviewing {
                            LabeledContent("Recipient receives", value: receiveXBT ? "XBT" : "Spamcoin (BTC)")
                            LabeledContent("Sender pays", value: receiveXBT ? "Spamcoin (BTC)" : "XBT")
                            DisclosureGroup("Receiving offer") { Text(destination).font(.caption.monospaced()).textSelection(.enabled) }
                            Text("The receiving wallet must stay reachable. This registers a reusable route to that wallet; it does not send funds. Revoking stops new payments while in-flight payments finish or refund.").font(.subheadline)
                            Button("Create reusable offer") { model.run { selected = try await model.create(destination: destination, receiveXBT: receiveXBT); reviewing = false } }.buttonStyle(WalletPrimaryButtonStyle())
                            Button("Edit") { reviewing = false }
                        } else {
                            Picker("Receiving currency", selection: $receiveXBT) { Text("Receive XBT").tag(true); Text("Receive BTC").tag(false) }.pickerStyle(.segmented)
                            TextField("Receiving wallet’s amountless BOLT12 offer", text: $destination, axis: .vertical).accessibilityIdentifier("bridge-reusable-destination").lineLimit(2...4).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Scan receiving offer") { scanning = true }
                            if receiveXBT {
                                Button("Use my connected Lightning node") {
                                    model.run {
                                        let receiver = LightningBridgeReceiveModel.shared
                                        let saved = try receiver.connection(), node = try await receiver.node(saved)
                                        let info = try JSONSerialization.jsonObject(with: await node.info()) as? [String: Any] ?? [:]
                                        guard try LightningNetwork.decode(info, implementation: saved.implementation) == .mainnet else { throw BridgeError.invalidInvoice }
                                        let offer = try await node.offer(amount: nil, description: "Paperclip Bridge")
                                        guard try receiver.connection() == saved else { throw BridgeError.invalidInvoice }
                                        destination = offer
                                    }
                                }
                            }
                            Text("Use a Lightning wallet’s amountless offer. Receiving into Ark through the bridge is not supported.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                            Button("Review offer") {
                                do { destination = destination.trimmingCharacters(in: .whitespacesAndNewlines); try BridgeReusableOffer.validateOffer(destination, xbt: receiveXBT); reviewing = true; localMessage = "" }
                                catch { localMessage = error.localizedDescription }
                            }.buttonStyle(WalletPrimaryButtonStyle()).disabled(destination.isEmpty || model.available != true)
                        }
                    }
                    if !reviewing { WalletSection("Your saved offers") {
                        ForEach(model.records.reversed()) { row in
                            Button { selected = row.id; showKey = false } label: {
                                WalletNavigationRow(row.binding == nil && row.receiveXBT == nil ? "Restore pending" : row.binding?.direction.targetIsXBT == true || row.receiveXBT == true ? "Receive XBT" : "Receive BTC", subtitle: row.binding?.revoked == true ? "Revoked" : row.binding == nil ? "Needs status check" : "Reusable offer", icon: "qrcode")
                            }.buttonStyle(.plain)
                        }
                        DisclosureGroup("Restore with a management key") {
                            SecureField("Private management key", text: $restoreKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Restore offer") { let key = restoreKey; restoreKey = ""; model.run { selected = try await model.restore(key) } }
                        }
                    }
                    }
                }
                if model.busy { ProgressView("Checking bridge…") }
                if !model.message.isEmpty { Text(model.message).font(.subheadline) }
                if !localMessage.isEmpty { Text(localMessage).font(.subheadline) }
            }.animation(reduceMotion ? nil : .snappy(duration: 0.18), value: reviewing).walletPageContent().textFieldStyle(WalletInputStyle()).disabled(model.busy || !model.loaded)
        }.walletPageBackground().navigationTitle("Reusable bridge").navigationBarTitleDisplayMode(.inline)
            .task(id: scenePhase) { guard scenePhase == .active else { return }; model.load(); while !Task.isCancelled { await model.health(); try? await Task.sleep(nanoseconds: 30_000_000_000) } }
            .fullScreenCover(isPresented: $scanning) { QRScannerView { destination = PaymentInput.normalized($0); reviewing = false } }
            .confirmationDialog("Stop new payments to this offer?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
                Button("Revoke offer", role: .destructive) { if let row = revoking { model.run { try await model.update(row, action: "revoke") } }; revoking = nil }
            } message: { Text("Payments already in progress can still finish or refund. The receiving wallet’s original offer remains unchanged.") }
    }
}
