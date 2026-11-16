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
    @Published var bondAddress: String?
    @Published var bondMonth = ""
    @Published var previewOnly = false
    @Published var needsRefresh = false
    private var client: JoinBlaketClient?
    private var authorization: JoinBlaketAuthorization?
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        Task { defer { busy = false }; do { try await action() } catch { message = error.localizedDescription } }
    }
    func connect() async throws {
        session = nil; authorization = nil; jars = []; address = nil; wallets = []; bondAddress = nil; bondMonth = ""
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
    func prepareBond(month: String) async throws {
        guard let client, let authorization else { throw JoinBlaketError.sessionExpired }
        bondAddress = nil; bondMonth = ""
        let address = try await client.bondAddress(month: month, authorization: authorization)
        bondMonth = month; bondAddress = address
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
    @State private var bondMonth = ""
    @State private var bondYear = Calendar(identifier: .gregorian).component(.year, from: Date())
    @State private var bondNumber = 0
    @State private var reviewedBondMonth = ""
    @State private var confirmBond = false
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
                        Text("\(Int(selectedJar) + 1) of 5").font(.caption.monospacedDigit()).foregroundStyle(PaperclipTheme.muted)
                        Spacer()
                        Button { model.perform { try await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh jars")
                    }
                    JarGridLayout {
                        ForEach(model.jars) { jar in
                            Button { selectedJar = jar.id; model.address = nil } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        JarIllustration(color: colors[Int(jar.id)], funded: jar.total_sat > 0)
                                            .scaleEffect(0.45).frame(width: 28, height: 32)
                                        Text(jar.name).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Text(unit.display(jar.total_sat)).font(.subheadline.monospacedDigit()).foregroundStyle(.primary)
                                    Text(jar.pending_sat > 0 ? "Incoming pending" : (selectedJar == jar.id ? "Selected" : "Jar \(Int(jar.id) + 1)"))
                                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                                }.frame(maxWidth: .infinity, minHeight: 78, alignment: .leading).padding(12)
                                    .background(colors[Int(jar.id)].opacity(selectedJar == jar.id ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 20))
                                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(selectedJar == jar.id ? colors[Int(jar.id)] : Color.clear, lineWidth: 2))
                            }.buttonStyle(WalletNavigationButtonStyle()).accessibilityIdentifier("jar-\(jar.id)").accessibilityAddTraits(selectedJar == jar.id ? .isSelected : [])
                        }
                    }.padding(2).accessibilityElement(children: .contain).accessibilityIdentifier("jar-picker")
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
                                LabeledContent("Minimum CoinJoin (sats)") {
                                    TextField("Minimum CoinJoin (sats)", text: $minimum).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                                }
                                LabeledContent("Your fee per CoinJoin (sats)") {
                                    TextField("Your fee per CoinJoin (sats)", text: $makerFee).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                                }
                                Text("Mining fee contribution: 0 sats. Earnings depend on being selected.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                                makerChecklist
                                if !makerReadiness.bond {
                                    Text("Bond coins stay locked until the date you choose and remain separate from your maker offer.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                                }
                                Text("Your server checks final eligibility; earnings are not guaranteed.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                            }
                            bondSetup
                            if model.needsRefresh { Text("Refresh maker status before another action.").font(.subheadline) }
                            Button(model.session?.maker_running == true ? "Stop maker" : "Review maker setup") { confirmMaker = true }
                            .disabled(model.previewOnly || model.needsRefresh || (model.session?.maker_running != true && !makerReadiness.canStart))
                        }
                    }
                }
                if model.busy { ProgressView().frame(maxWidth: .infinity) }
                if let message = model.message { Text(message).font(.subheadline).textSelection(.enabled) }
            }.walletPageContent()
        }.walletPageBackground().navigationTitle("Jars").navigationBarTitleDisplayMode(.inline)
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
            .alert("Create bond address?", isPresented: $confirmBond) {
                Button("Create address") {
                    let month = reviewedBondMonth
                    model.perform { try await model.prepareBond(month: month) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Wallet: \(model.selectedWallet). Coins sent here will be locked until \(reviewedBondMonth)-01 at 00:00 UTC. Creating the address sends no funds. Review the amount and mining fee separately when funding. Earnings are not guaranteed.")
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
            makerStep(ready.bond, "Bond funds detected", "Set up and fund a fidelity bond")
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
    private var bondSetup: some View {
        DisclosureGroup("Set up a fidelity bond") {
            Text("A bond locks coins until your chosen month. It may help your maker get selected; earnings are not guaranteed.").font(.subheadline)
            LabeledContent("Unlock month") {
                Picker("Unlock month", selection: $bondNumber) {
                    Text("Choose month").tag(0)
                    ForEach(1...12, id: \.self) { month in Text(Calendar.current.monthSymbols[month - 1]).tag(month) }
                }.labelsHidden()
            }
            LabeledContent("Unlock year") {
                Picker("Unlock year", selection: $bondYear) {
                    ForEach(min(2099, Calendar(identifier: .gregorian).component(.year, from: Date()))...2099, id: \.self) { year in Text(String(year)).tag(year) }
                }.labelsHidden()
            }
            .onChange(of: bondYear) { _, _ in updateBondMonth() }
            .onChange(of: bondNumber) { _, _ in updateBondMonth() }
            Text("Unlocks on the first day at 00:00 UTC. Creating the address sends no funds.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            Button("Review bond address") {
                do { try JoinBlaketBond.validate(month: bondMonth); reviewedBondMonth = bondMonth; confirmBond = true }
                catch { model.message = error.localizedDescription }
            }.disabled(model.previewOnly)
            if let address = model.bondAddress {
                Text("Wallet: \(model.selectedWallet) · Unlocks \(model.bondMonth)-01 at 00:00 UTC.").font(.subheadline)
                Text("Address ready; no funds sent. Back up your Jam wallet, then review the amount and mining fee in the wallet you fund it from.").font(.caption)
                ReceiveCode(value: address).frame(maxWidth: .infinity)
                Text(address).font(.footnote.monospaced()).textSelection(.enabled)
                ShareLink(item: address) { Label("Share bond address", systemImage: "square.and.arrow.up") }
            }
        }
    }
    private func updateBondMonth() {
        bondMonth = String(format: "%04d-%02d", bondYear, bondNumber)
        model.bondAddress = nil; model.bondMonth = ""
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

/// Two equal columns with an odd final jar centered. Heights grow with larger text.
private struct JarGridLayout: Layout {
    private let gap: CGFloat = 12
    private func rowHeights(_ width: CGFloat, _ views: Subviews) -> [CGFloat] {
        let cellWidth = max(0, (width - gap) / 2)
        return stride(from: 0, to: views.count, by: 2).map { start in
            (start..<min(start + 2, views.count)).map {
                views[$0].sizeThatFits(.init(width: cellWidth, height: nil)).height
            }.max() ?? 0
        }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let heights = rowHeights(width, subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + gap * CGFloat(max(0, heights.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = max(0, (bounds.width - gap) / 2)
        var y = bounds.minY
        for (row, height) in rowHeights(bounds.width, subviews).enumerated() {
            let start = row * 2
            let count = min(2, subviews.count - start)
            let x = count == 1 ? bounds.midX - width / 2 : bounds.minX
            for column in 0..<count {
                subviews[start + column].place(at: .init(x: x + CGFloat(column) * (width + gap), y: y), anchor: .topLeading,
                    proposal: .init(width: width, height: height))
            }
            y += height + gap
        }
    }
}
