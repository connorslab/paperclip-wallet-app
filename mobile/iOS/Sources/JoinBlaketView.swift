import SwiftUI
import PaperclipMobile

@MainActor private final class JoinBlaketModel: ObservableObject {
    @Published var connection = JoinBlaketConnection()
    @Published var wallets: [String] = []
    @Published var selectedWallet = ""
    @Published var jars: [JoinBlaketJar] = []
    @Published var session: JoinBlaketSession?
    @Published var busy = false
    @Published var message: String?
    @Published var address: String?
    @Published var previewOnly = false
    @Published var needsRefresh = false
    private var client: JoinBlaketClient?
    private var authorization: JoinBlaketAuthorization?
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        Task { defer { busy = false }; do { try await action() } catch { message = error.localizedDescription } }
    }
    func connect() async throws {
        session = nil; authorization = nil; jars = []; address = nil; wallets = []
        var resolved = connection
        if resolved.useTor { resolved.torProxy = try await EmbeddedTor.shared.proxy(for: resolved.torProxy) }
        let candidate = try JoinBlaketClient(connection: resolved)
        wallets = try await candidate.wallets()
        client = candidate; selectedWallet = wallets.first ?? ""
        if wallets.isEmpty { message = "Create a separate wallet in Jam, then refresh this connection." }
    }
    func unlock(password: String, passphrase: String) async throws {
        guard let client else { return }
        authorization = try await client.unlock(wallet: selectedWallet, password: password, passphrase: passphrase)
        try await refresh()
    }
    func refresh() async throws {
        guard let client, let authorization else { return }
        needsRefresh = true
        let current = try await client.status(authorization)
        let normalized = try await NativeWallet.shared.joinBlaketJars(client.coins(authorization))
        struct Response: Decodable { let jars: [JoinBlaketJar] }
        let data = try JSONSerialization.data(withJSONObject: normalized)
        jars = try JSONDecoder().decode(Response.self, from: data).jars
        session = current; needsRefresh = false
    }
    func receive(_ jar: JoinBlaketJar) async throws {
        guard let client, let authorization else { return }
        address = try await client.receiveAddress(jar: jar.id, authorization: authorization)
    }
    func maker(start: Bool, minimum: UInt64, fee: UInt64) async throws {
        guard let client, let authorization else { return }
        needsRefresh = true
        if start { try await client.startMaker(minimumSat: minimum, feeSat: fee, authorization: authorization) }
        else { try await client.stopMaker(authorization: authorization) }
        try await refresh()
    }
#if DEBUG
    func preview() async throws {
        previewOnly = true
        selectedWallet = "UI test fixture · no live funds"
        let rows: [[String: Any]] = [
            ["utxo": String(repeating: "00", count: 32) + ":0", "value": 200000, "mixdepth": 0, "confirmations": 6, "frozen": false],
            ["utxo": String(repeating: "00", count: 32) + ":1", "value": 75000, "mixdepth": 1, "confirmations": 0, "frozen": false],
        ]
        let normalized = try await NativeWallet.shared.joinBlaketJars(JSONSerialization.data(withJSONObject: ["utxos": rows]))
        struct Response: Decodable { let jars: [JoinBlaketJar] }
        jars = try JSONDecoder().decode(Response.self, from: JSONSerialization.data(withJSONObject: normalized)).jars
        session = try JSONDecoder().decode(JoinBlaketSession.self, from: Data("{\"session\":true,\"maker_running\":false,\"coinjoin_in_process\":false,\"wallet_name\":\"fixture\",\"rescanning\":false}".utf8))
    }
#endif
}

struct JoinBlaketView: View {
    @StateObject private var model = JoinBlaketModel()
    @State private var password = ""
    @State private var passphrase = ""
    @State private var selectedJar: UInt8 = 0
    @State private var minimum = "100000"
    @State private var makerFee = "100"
    @State private var confirmMaker = false
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    private let colors: [Color] = [.orange, .blue, .red, .brown, .purple]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.session == nil {
                    WalletSection {
                        Label("JoinBlaket", systemImage: "shuffle").font(.headline)
                        Text("Your CoinJoin wallet").font(.title.bold())
                        Text("Connect your Jam server to manage five separate jars and run a maker.").foregroundStyle(PaperclipTheme.muted)
                        Link("Set up Kilombino JoinBlaket", destination: URL(string: "https://kilombino.com/joinblaket/")!)
                    }
                    connection
                } else {
                    WalletSection {
                        HStack {
                            Label("CoinJoin balance", systemImage: "shuffle").foregroundStyle(PaperclipTheme.muted)
                            Spacer()
                            Text("Experimental").font(.caption).foregroundStyle(PaperclipTheme.muted)
                        }
                        Text(unit.display(model.jars.reduce(UInt64(0)) { $0 + $1.total_sat })).font(.largeTitle.bold()).monospacedDigit()
                        Text(model.selectedWallet).font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    }
                    HStack {
                        Text("Your jars").font(.title2.bold())
                        Spacer()
                        Button { model.perform { try await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh jars")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                        ForEach(model.jars) { jar in
                            Button { selectedJar = jar.id; model.address = nil } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    JarIllustration(color: colors[Int(jar.id)], funded: jar.total_sat > 0).frame(height: 70)
                                    Text(jar.name).font(.headline)
                                    Text(unit.display(jar.total_sat)).font(.subheadline.monospacedDigit())
                                    Text(jar.pending_sat > 0 ? "Incoming pending" : " ").font(.caption).foregroundStyle(PaperclipTheme.muted).accessibilityHidden(jar.pending_sat == 0)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                                    .background(colors[Int(jar.id)].opacity(0.10), in: RoundedRectangle(cornerRadius: 22))
                                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(selectedJar == jar.id ? colors[Int(jar.id)] : Color.clear, lineWidth: 2))
                            }.buttonStyle(.plain).accessibilityAddTraits(selectedJar == jar.id ? .isSelected : [])
                        }
                    }
                    WalletColumns {
                        if let jar = model.jars.first(where: { $0.id == selectedJar }) {
                            WalletSection(jar.name) {
                                LabeledContent("Confirmed", value: unit.display(jar.confirmed_sat))
                                if jar.pending_sat > 0 { LabeledContent("Pending", value: unit.display(jar.pending_sat)) }
                                if jar.frozen_sat > 0 { LabeledContent("Frozen", value: unit.display(jar.frozen_sat)) }
                                if jar.bond_sat > 0 { LabeledContent("Fidelity bonds", value: unit.display(jar.bond_sat)) }
                                Button { model.perform { try await model.receive(jar) } } label: { Label("Receive into \(jar.name)", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction()).disabled(model.previewOnly)
                                if let address = model.address {
                                    ReceiveCode(value: address).frame(maxWidth: .infinity)
                                    Text(address).font(.footnote.monospaced()).textSelection(.enabled)
                                    ShareLink(item: address) { Label("Share address", systemImage: "square.and.arrow.up") }
                                }
                            }
                        }
                    } secondary: {
                        WalletSection("Maker") {
                            Label(model.session?.maker_running == true ? "Running on your server" : "Not running", systemImage: model.session?.maker_running == true ? "checkmark.circle.fill" : "pause.circle")
                            Text("Your server can keep making while Paperclip is closed.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                            if model.session?.maker_running != true {
                                TextField("Minimum CoinJoin (sats)", text: $minimum).keyboardType(.numberPad)
                                TextField("Your fee per CoinJoin (sats)", text: $makerFee).keyboardType(.numberPad)
                                Text("Mining fee contribution: 0 sats. Earnings depend on being selected.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                                makerChecklist
                                if !makerReadiness.bond {
                                    Text("Bond coins stay locked until the date you choose and remain separate from your maker offer.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                                    jamHandoff
                                }
                                Text("Your server checks final eligibility; earnings are not guaranteed.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                            }
                            if model.needsRefresh { Text("Refresh maker status before another action.").font(.subheadline) }
                            Button(model.session?.maker_running == true ? "Stop maker" : "Review maker setup") { confirmMaker = true }
                            .disabled(model.previewOnly || model.needsRefresh || (model.session?.maker_running != true && !makerReadiness.canStart))
                        }
                    }
                }
                if model.busy { ProgressView().frame(maxWidth: .infinity) }
                if let message = model.message { Text(message).font(.subheadline).textSelection(.enabled) }
                NavigationLink { CoinjoinView() } label: { WalletNavigationRow("Previous CoinJoin account", subtitle: "Kilojoin funds and round recovery", icon: "clock.arrow.circlepath") }
            }.walletPageContent()
        }.walletPageBackground().navigationTitle("CoinJoin").navigationBarTitleDisplayMode(.inline)
            .disabled(model.busy)
#if DEBUG
            .task {
                if ProcessInfo.processInfo.arguments.contains("-joinblaket-preview") {
                    do { try await model.preview() } catch { model.message = error.localizedDescription }
                }
            }
#endif
            .confirmationDialog(model.session?.maker_running == true ? "Stop your server’s maker?" : "Start making on your Jam server?", isPresented: $confirmMaker) {
                Button(model.session?.maker_running == true ? "Stop maker" : "Start maker") {
                    model.perform { try await model.maker(start: model.session?.maker_running != true, minimum: UInt64(minimum) ?? 0, fee: UInt64(makerFee) ?? 0) }
                }
            } message: {
                Text(model.session?.maker_running == true ? "Existing CoinJoins may need to finish before the maker stops." : "Minimum CoinJoin: \(minimum) sats. Your fee: \(makerFee) sats per CoinJoin. Mining fee contribution: 0 sats. The maker uses eligible Jam jars and keeps running when Paperclip closes.")
            }
    }
    private var makerReadiness: JoinBlaketMakerReadiness {
        JoinBlaketMakerReadiness(minimum: minimum, fee: makerFee, jars: model.jars, session: model.session, needsRefresh: model.needsRefresh)
    }
    private var makerChecklist: some View {
        let ready = makerReadiness
        return VStack(alignment: .leading, spacing: 12) {
            makerStep(ready.terms, "Amount and fee valid", "Review the minimum amount and fee")
            makerStep(ready.funds, "One jar covers the minimum", "Fund one jar and wait for confirmation")
            makerStep(ready.bond, "Bond funds detected", "Set up a JoinBlaket fidelity bond in Jam")
            makerStep(ready.server, "Jam is idle", "Wait for Jam to finish syncing or its current operation")
            makerStep(ready.fresh, "Status refreshed", "Refresh wallet status before continuing")
        }.padding(.vertical, 8).accessibilityElement(children: .contain).accessibilityLabel("Maker setup")
    }
    private func makerStep(_ complete: Bool, _ ready: String, _ needed: String) -> some View {
        Label(complete ? ready : needed, systemImage: complete ? "checkmark.circle.fill" : "circle")
            .font(.subheadline).foregroundStyle(complete ? PaperclipTheme.muted : PaperclipTheme.orange)
            .accessibilityLabel((complete ? "Ready: " : "Needed: ") + (complete ? ready : needed))
    }
    private var connection: some View {
        WalletSection("Connect to Jam") {
            TextField("HTTPS or onion address", text: $model.connection.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField("Certificate SHA256 (optional)", text: $model.connection.certificateSHA256).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Use Tor", isOn: $model.connection.useTor)
            Button("Find wallets") { model.perform { try await model.connect() } }.modifier(GlassAction())
            if !model.wallets.isEmpty {
                Picker("Wallet", selection: $model.selectedWallet) { ForEach(model.wallets, id: \.self) { Text($0).tag($0) } }
                SecureField("Jam wallet password", text: $password)
                DisclosureGroup("Wallet passphrase") {
                    SecureField("BIP39 passphrase, if your Jam wallet uses one", text: $passphrase)
                }
                Button("Unlock and view jars") {
                    let entered = password, enteredPassphrase = passphrase
                    password = ""; passphrase = ""
                    model.perform { try await model.unlock(password: entered, passphrase: enteredPassphrase) }
                }.modifier(GlassAction())
            }
        }
    }
    @ViewBuilder private var jamHandoff: some View {
        if let url = URL(string: model.connection.endpoint), url.scheme == "https", url.host?.hasSuffix(".onion") == false {
            Link("Open Jam to set up your bond", destination: url)
        } else if !model.connection.endpoint.isEmpty {
            Text("Open your Jam address in a Tor browser, then refresh your jars here.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            ShareLink(item: model.connection.endpoint) { Label("Jam server address", systemImage: "square.and.arrow.up") }
        }
    }
}

private struct JarIllustration: View {
    let color: Color
    let funded: Bool
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.06))
            RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.35)).frame(height: funded ? 35 : 4).padding(5)
            RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.65), lineWidth: 2)
            Capsule().fill(color).frame(height: 7).offset(y: -64)
        }.frame(width: 56, height: 62).frame(maxWidth: .infinity).accessibilityHidden(true)
    }
}
