import SwiftUI
import PaperclipMobile

private struct JarsSendView: View {
    let jar: JoinBlaketJar
    let wallet: String
    let previewOnly: Bool
    let prepare: (JoinBlaketSendDraft) async throws -> JoinBlaketSendReview
    let commit: (JoinBlaketSendReview, JoinBlaketSendDraft) async throws -> JoinBlaketPayment
    let discard: (String) async throws -> JoinBlaketPayment
    let activity: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var amount = ""
    @State private var rate = "1"
    @State private var feeLimit = "1000"
    @State private var coinjoin = false
    @State private var busy = false
    @State private var attempted = false
    @State private var submitting = false
    @State private var draft: JoinBlaketSendDraft?
    @State private var review: JoinBlaketSendReview?
    @State private var result: JoinBlaketPayment?
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let review, let draft, result == nil {
                        WalletSection("Review jar payment") {
                            PaymentReviewHero(amount: "\(draft.amountSat.formatted()) sats", source: jar.name)
                            LabeledContent("From", value: jar.name)
                            LabeledContent("Payment type", value: draft.coinjoin ? "CoinJoin" : "Direct · no CoinJoin")
                            if let q = review.payment.quote {
                                if draft.coinjoin {
                                    WalletReviewDetail(title: "Maker fees", value: "\((q.maker_fee_sat ?? 0).formatted()) sats")
                                    WalletReviewDetail(title: "Your mining fee", value: "\((q.mining_fee_sat ?? 0).formatted()) sats")
                                    Text("With \(q.maker_count ?? 0) makers · sent through your Jam node").font(.caption)
                                    Text("CoinJoin does not use RBF. Discarding a review may leave coins reserved briefly.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                                } else { WalletReviewDetail(title: "Mining fee", value: "\(q.fee_sat.formatted()) sats") }
                                WalletReviewDetail(title: "Total debit", value: "\(q.total_sat.formatted()) sats", emphasized: true)
                            }
                            Text(draft.destination).font(.footnote.monospaced()).textSelection(.enabled)
                            Text("Wallet: \(wallet)").font(.caption).foregroundStyle(PaperclipTheme.muted)
                            Text("Review expires \(Date(timeIntervalSince1970: Double(review.expires)), style: .time)").font(.caption)
                            Button("Send payment") { run { submitting = true; self.review = nil; result = try await commit(review, draft) } }
                                .buttonStyle(WalletPrimaryButtonStyle())
                            Button("Discard unsent review", role: .cancel) { run { _ = try await discard(draft.id); self.review = nil; self.draft = nil; attempted = false } }
                        }
                    } else if let result {
                        WalletSection(result.state.label) {
                            Text(result.state == .submitted ? "The transaction was submitted. Confirmation is still pending." : "The payment may have reached the network. Check its status before another action.")
                            Button("View payment activity", action: activity).buttonStyle(WalletPrimaryButtonStyle())
                        }
                    } else if busy && attempted {
                        WalletSection(submitting ? "Submitting payment" : draft?.coinjoin == true ? "Preparing CoinJoin" : "Preparing payment") {
                            Text(submitting ? "Waiting for your Jam node. Keep this screen open; the payment will not be sent again automatically." : draft?.coinjoin == true ? "Finding participants and checking the exact fees. This can take up to three minutes. Nothing is broadcast until you review and send." : "Checking the recipient, coins and fees before review.")
                        }
                    } else if attempted {
                        WalletSection("Check payment activity") {
                            Text("A request was started. Its saved state must be checked before creating another payment.")
                            Button("View payment activity", action: activity).buttonStyle(WalletPrimaryButtonStyle())
                        }
                    } else {
                        WalletSection("Send from \(jar.name)") {
                            TextField("XBT address", text: $destination).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Amount (sats)", text: $amount).keyboardType(.numberPad)
                            Toggle("CoinJoin", isOn: $coinjoin).accessibilityIdentifier("jars-send-coinjoin")
                            Text(coinjoin ? "Pay with other participants. Review maker and mining fees before sending. If CoinJoin is unavailable, no direct payment is made." : "Direct payment. This transaction will not use CoinJoin.")
                                .font(.caption).foregroundStyle(PaperclipTheme.muted)
                            LabeledContent("Mining rate (sat/vB)") { TextField("1", text: $rate).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                            LabeledContent("Maximum total fees (sats)") { TextField("1000", text: $feeLimit).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                            Button("Review payment") {
                                run {
                                    guard let sats = UInt64(amount), let rate = UInt64(rate), rate <= 10000, let maxFee = UInt64(feeLimit) else { throw JoinBlaketError.invalidResponse }
                                    let value = try JoinBlaketSendDraft(jar: jar.id, destination: destination.trimmingCharacters(in: .whitespacesAndNewlines), amountSat: sats, feeRateMillisatVb: rate * 1000, maxFeeSat: maxFee, coinjoin: coinjoin)
                                    submitting = false; draft = value; attempted = true
                                    review = try await prepare(value)
                                }
                            }.buttonStyle(WalletPrimaryButtonStyle()).disabled(previewOnly)
                        }
                    }
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    if let message { Text(message).font(.subheadline) }
                }.walletPageContent().id("jar-send-content").textFieldStyle(WalletInputStyle()).disabled(busy)
            }.walletPageBackground().navigationTitle("Jar payment").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .onDisappear { task?.cancel() }
                .onChange(of: review?.payment.id) { _, _ in proxy.scrollTo("jar-send-content", anchor: .top) }
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        task = Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { message = error.localizedDescription }
        }
    }
}

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
    @Published var paired = false
    @Published var canSend = true
    func pair(_ text: String, save: Bool = true) async throws {
        let pairing = try JoinBlaketPairing(text: text)
        var resolved = pairing.connection
        if resolved.useTor { resolved.torProxy = try await EmbeddedTor.shared.proxy(for: resolved.torProxy) }
        let candidate = try JoinBlaketClient(connection: resolved, pairing: pairing)
        let auth = try pairing.authorization()
        let current = try await candidate.status(auth)
        let normalized = try await NativeWallet.shared.joinBlaketJars(candidate.coins(auth))
        struct Response: Decodable { let jars: [JoinBlaketJar] }
        let rows = try JSONDecoder().decode(Response.self, from: JSONSerialization.data(withJSONObject: normalized)).jars
        if save { try WalletKeychain.save(Data(text.utf8), account: "jars-pairing-v1") }
        client = candidate; authorization = auth; selectedWallet = pairing.wallet
        session = current; jars = rows; paired = true; canSend = pairing.canSend; needsRefresh = false
        address = nil; bondAddress = nil; bondMonth = ""
    }
    func forgetPairing() throws {
        try WalletKeychain.delete("jars-pairing-v1")
        client = nil; authorization = nil; session = nil; jars = []; paired = false; canSend = true
        selectedWallet = ""; wallets = []; address = nil; bondAddress = nil; bondMonth = ""
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        Task { defer { busy = false }; do { try await action() } catch { message = error.localizedDescription } }
    }
    func connect() async throws {
        paired = false; canSend = true
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
    func payments() async throws -> [JoinBlaketPayment] {
#if DEBUG
        if previewOnly { return [try previewPayment()] }
#endif
        guard let client, let authorization else { throw JoinBlaketError.sessionExpired }
        return try await client.payments(authorization)
    }
    func checkPayment(_ id: String) async throws -> JoinBlaketPayment {
#if DEBUG
        if previewOnly {
            previewRecoveryChecks += 1
            if previewRecoveryChecks == 1 { throw URLError(.timedOut) }
            return try previewPayment()
        }
#endif
        guard let client, let authorization else { throw JoinBlaketError.sessionExpired }
        return try await client.checkPayment(id: id, authorization: authorization)
    }
    func market(_ amount: UInt64) async throws -> JoinBlaketMarket {
        guard !previewOnly, let client, let authorization else { throw JoinBlaketError.sessionExpired }
        return try await client.market(amount: amount, authorization: authorization)
    }
    func prepareSend(_ draft: JoinBlaketSendDraft) async throws -> JoinBlaketSendReview {
        guard !previewOnly, canSend, let client, let authorization else { throw JoinBlaketError.sessionExpired }
        needsRefresh = true
        return try await client.prepareSend(draft, authorization: authorization)
    }
    func commitSend(_ review: JoinBlaketSendReview, _ draft: JoinBlaketSendDraft) async throws -> JoinBlaketPayment {
        guard !previewOnly, canSend, let client, let authorization else { throw JoinBlaketError.sessionExpired }
        return try await client.commitSend(review, draft: draft, authorization: authorization)
    }
    func discardPayment(_ id: String) async throws -> JoinBlaketPayment {
        guard !previewOnly, let client, let authorization else { throw JoinBlaketError.sessionExpired }
        return try await client.discardPayment(id: id, authorization: authorization)
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
    func maker(start: Bool, minimum: UInt64, fee: UInt64, relativeFee: String? = nil) async throws {
        guard let client, let authorization else { return }
        needsRefresh = true
        if start { try await client.startMaker(minimumSat: minimum, feeSat: fee, authorization: authorization, relativeFee: relativeFee) }
        else { try await client.stopMaker(authorization: authorization) }
        try await refresh()
    }
#if DEBUG
    private var previewRecoveryChecks = 0
    private func previewPayment() throws -> JoinBlaketPayment {
        let data = try JSONSerialization.data(withJSONObject: ["id": String(repeating: "a", count: 64),
            "state": previewRecoveryChecks > 1 ? "submitted" : "unknown",
            "quote": ["wallet": "UI fixture · no live funds", "jar": 2, "purpose": "send",
                "destination": "bc1qsyntheticdestination", "txid": String(repeating: "b", count: 64),
                "amount_sat": 20000, "fee_sat": 140, "total_sat": 20140]])
        return try JSONDecoder().decode(JoinBlaketPayment.self, from: data)
    }
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
    private enum MakerPage: String, Hashable {
        case settings = "Maker settings", market = "Market fees", bond = "Fidelity bond", guide = "How earning works"
    }
    @State private var makerPage: MakerPage?
    @State private var sendJar: JoinBlaketJar?
    @State private var openSendActivity = false

    @StateObject private var model = JoinBlaketModel()
    @State private var password = ""
    @State private var passphrase = ""
    @State private var selectedJar: UInt8 = 0
    @State private var minimum = "100000"
    @State private var makerFee = "100"
    @State private var relativeMode = false
    @State private var relativeRate = "0.00005"
    @State private var comparisonAmount = "100000"
    @State private var market: JoinBlaketMarket?
    @State private var marketUnavailable = false
    @State private var confirmMaker = false
    @State private var showPayments = false
    @State private var bondMonth = ""
    @State private var bondYear = Calendar(identifier: .gregorian).component(.year, from: Date())
    @State private var bondNumber = 0
    @State private var reviewedBondMonth = ""
    @State private var confirmBond = false
    @State private var pairingText = ""
    @State private var pairingReview: JoinBlaketPairing?
    @State private var scanningPairing = false
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    private let colors: [Color] = [.orange, .blue, .red, .brown, .purple]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.session == nil {
                    WalletSection {
                        Label("JoinBlaket", systemImage: "shuffle").font(.headline)
                        Text("Pair with Paperclip on your server to manage five jars and earn as a maker.").foregroundStyle(PaperclipTheme.muted)
                    }
                    pairingSetup
                    DisclosureGroup("Connect to a separate Jam server") { connection }
                } else {
                    connectedContent
                }
                if model.busy { ProgressView().frame(maxWidth: .infinity) }
                if let message = model.message { Text(message).font(.subheadline).textSelection(.enabled) }
            }.walletPageContent()
        }.walletPageBackground().navigationTitle("Jars").navigationBarTitleDisplayMode(.inline)
            .onChange(of: comparisonAmount) { _, _ in market = nil; marketUnavailable = false }
            .onChange(of: model.connection.endpoint) { _, _ in makerPage = nil; market = nil; marketUnavailable = false }
            .onChange(of: model.selectedWallet) { _, _ in makerPage = nil; market = nil; marketUnavailable = false }
            .onChange(of: makerPage) { _, _ in confirmMaker = false; confirmBond = false }
            .disabled(model.busy)
            .navigationDestination(item: $makerPage) { toolPage($0) }
            .sheet(item: $sendJar, onDismiss: { if openSendActivity { openSendActivity = false; showPayments = true } }) { jar in
                NavigationStack {
                    JarsSendView(jar: jar, wallet: model.selectedWallet, previewOnly: model.previewOnly,
                        prepare: model.prepareSend, commit: model.commitSend, discard: model.discardPayment,
                        activity: { openSendActivity = true; sendJar = nil })
                }
            }
            .sheet(isPresented: $showPayments) {
                JoinBlaketRecoveryView(load: model.payments, check: model.checkPayment, discard: discardAction)
            }
            .fullScreenCover(isPresented: $scanningPairing) {
                QRScannerView { value in
                    do { pairingReview = try JoinBlaketPairing(text: value); pairingText = value }
                    catch { model.message = "Scan a current Paperclip Jars pairing code." }
                }
            }
#if DEBUG
            .task {
                if ProcessInfo.processInfo.arguments.contains("-joinblaket-preview") {
                    do { try await model.preview(); showPayments = ProcessInfo.processInfo.arguments.contains("-jam-recovery-preview") } catch { model.message = error.localizedDescription }
                }
            }
#endif

    }
    private var discardAction: ((String) async throws -> JoinBlaketPayment)? {
        guard model.canSend else { return nil }
        return { id in try await model.discardPayment(id) }
    }
    @ViewBuilder private var connectedContent: some View {
        WalletSection {
            HStack {
                Label("CoinJoin balance", systemImage: "shuffle").foregroundStyle(PaperclipTheme.muted)
                Spacer()
                Text("Experimental").font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
            Text(unit.display(model.jars.reduce(UInt64(0)) { $0 + $1.total_sat })).font(.largeTitle.bold()).monospacedDigit()
            Text(model.selectedWallet).font(.subheadline).foregroundStyle(PaperclipTheme.muted)
            if model.paired {
                Text("Paired with your Paperclip host").font(.caption).foregroundStyle(PaperclipTheme.muted)
                Button("Forget this connection", role: .destructive) { model.perform { try model.forgetPairing() } }
            }
        }
        HStack {
            Text("Your jars").font(.title2.bold())
            Text("\(Int(selectedJar) + 1) of 5").font(.caption.monospacedDigit()).foregroundStyle(PaperclipTheme.muted)
            Spacer()
            Button { model.perform { try await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh jars")
        }
        jarPicker
        Button { showPayments = true } label: {
            Label("Jars payment activity", systemImage: "clock.arrow.circlepath")
        }.disabled(model.previewOnly)
        WalletColumns {
            if let jar = model.jars.first(where: { $0.id == selectedJar }) {
                WalletSection(jar.name) {
                    LabeledContent("Confirmed", value: unit.display(jar.confirmed_sat))
                    if jar.pending_sat > 0 { LabeledContent("Pending", value: unit.display(jar.pending_sat)) }
                    if jar.frozen_sat > 0 { LabeledContent("Frozen", value: unit.display(jar.frozen_sat)) }
                    if jar.bond_sat > 0 { LabeledContent("Fidelity bonds", value: unit.display(jar.bond_sat)) }
                    Button { sendJar = jar } label: { Label("Send from \(jar.name)", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }
                        .buttonStyle(WalletPrimaryButtonStyle()).disabled(!model.canSend)
                    if !model.canSend { Text("This pairing manages jars. Sending requires a payment-authorized connection.").font(.caption).foregroundStyle(PaperclipTheme.muted) }
                    Button { model.perform { try await model.receive(jar) } } label: { Label("Receive into \(jar.name)", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction()).disabled(model.previewOnly)
                    if let address = model.address {
                        ReceiveCode(value: address).frame(maxWidth: .infinity)
                        Text(address).font(.footnote.monospaced()).textSelection(.enabled)
                        ShareLink(item: address) { Label("Share address", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        } secondary: {
            makerSection
        }
    }
    private var makerSection: some View {
        WalletSection("Earn with your jars") {
            HStack {
                Label(model.session?.maker_running == true ? "Maker running" : "Maker paused", systemImage: model.session?.maker_running == true ? "checkmark.circle.fill" : "pause.circle")
                Spacer()
                Text("Server").font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
            if model.session?.maker_running != true {
                Text(makerReadiness.nextStep).font(.subheadline).foregroundStyle(PaperclipTheme.muted)
            }
            makerRoute(.settings, subtitle: "Your fee and minimum amount", icon: "slider.horizontal.3")
            Divider()
            makerRoute(.market, subtitle: "Compare current maker fees", icon: "chart.bar")
            Divider()
            makerRoute(.bond, subtitle: "Lock date and bond address", icon: "lock.shield")
            Divider()
            makerRoute(.guide, subtitle: "A short guide to earning", icon: "questionmark.circle")
        }
    }
    private func makerRoute(_ page: MakerPage, subtitle: String, icon: String) -> some View {
        Button { makerPage = page } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 28).foregroundStyle(PaperclipTheme.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.rawValue).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(PaperclipTheme.muted)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(WalletNavigationButtonStyle()).accessibilityIdentifier("jars-tool-" + String(describing: page))
    }
    private func toolPage(_ page: MakerPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch page {
                case .settings: makerSettings
                case .market: marketSettings
                case .bond: bondSetup
                case .guide: makerGuide
                }
                if model.busy { ProgressView().frame(maxWidth: .infinity) }
                if let message = model.message { Text(message).font(.subheadline) }
            }.walletPageContent()
        }.walletPageBackground().navigationTitle(page.rawValue).navigationBarTitleDisplayMode(.inline)
            .disabled(model.busy)
            .confirmationDialog(model.session?.maker_running == true ? "Stop your server’s maker?" : "Start making on your Jam server?", isPresented: $confirmMaker) {
                Button(model.session?.maker_running == true ? "Stop maker" : "Start maker") {
                    model.perform { try await model.maker(start: model.session?.maker_running != true, minimum: UInt64(minimum) ?? 0, fee: relativeMode ? 0 : (UInt64(makerFee) ?? 0), relativeFee: relativeMode ? relativeRate : nil) }
                }
            } message: {
                Text(model.session?.maker_running == true ? "Existing CoinJoins may need to finish before the maker stops." : "Minimum CoinJoin: \(minimum) sats. Your fee: \(relativeMode ? JoinBlaketMakerFee.label(relativeRate) + " of the CoinJoin amount" : makerFee + " sats per CoinJoin"). Mining fee contribution: 0 sats. The maker uses eligible Jam jars and keeps running when Paperclip closes.")
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
    private var makerSettings: some View {
        WalletSection("Your maker offer") {
            if model.session?.maker_running != true {
                amountField("Minimum CoinJoin", text: $minimum, accessibility: "Minimum CoinJoin (sats)")
                Picker("Maker fee type", selection: $relativeMode) {
                    Text("Fixed sats").tag(false); Text("Percentage").tag(true)
                }.pickerStyle(.segmented)
                if relativeMode {
                    LabeledContent("Your fee") {
                        Picker("Your fee", selection: $relativeRate) {
                            ForEach(JoinBlaketMakerFee.rates, id: \.self) { Text(JoinBlaketMakerFee.label($0)).tag($0) }
                        }.pickerStyle(.menu).labelsHidden()
                    }
                    Text(JoinBlaketMakerFee.example(relativeRate)).font(.caption).foregroundStyle(PaperclipTheme.muted)
                } else {
                    LabeledContent("Your fee") {
                        Picker("Your fee per CoinJoin", selection: $makerFee) {
                            ForEach(JoinBlaketMakerFee.fixed, id: \.self) { Text("\($0) sats").tag(String($0)) }
                        }.pickerStyle(.menu).labelsHidden()
                    }
                }
                Text("Your fee is paid to you when selected. Earnings are not guaranteed.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                Text(makerReadiness.nextStep).font(.subheadline).foregroundStyle(makerReadiness.canStart ? PaperclipTheme.muted : PaperclipTheme.orange)
                DisclosureGroup("Setup checks · \(makerReadiness.completedChecks) of 5") { makerChecklist }
            }
            if model.session?.maker_running == true && model.needsRefresh { Text("Refresh maker status before continuing.").font(.subheadline) }
            Button(model.session?.maker_running == true ? "Stop maker" : "Review maker setup") { confirmMaker = true }
            .buttonStyle(WalletPrimaryButtonStyle())
            .disabled(model.previewOnly || model.needsRefresh || (model.session?.maker_running != true && !makerReadiness.canStart))
        }
    }
    private var marketSettings: some View {
        WalletSection("Order book") {
            amountField("CoinJoin amount", text: $comparisonAmount, accessibility: "Compare CoinJoin amount (sats)")
            Text("Compare at this CoinJoin amount. One lowest supported offer per verified bonded maker; mining fees are excluded.").font(.caption)
            TimelineView(.periodic(from: .now, by: 15)) { context in
                if let market { Text(market.summary(now: context.date)).font(.subheadline) }
            }
            if let market { Text("Fetched \(Date(timeIntervalSince1970: Double(market.fetched_at)), style: .time)").font(.caption).foregroundStyle(PaperclipTheme.muted) }
            if marketUnavailable { Text("Order book unavailable. Your selected fee is unchanged.").font(.caption) }
            Button("Refresh market fees") { model.perform {
                market = nil; marketUnavailable = false
                do { market = try await model.market(UInt64(comparisonAmount) ?? 0) } catch { marketUnavailable = true }
            } }.disabled(model.previewOnly)
            Text("A market snapshot is not a forecast. Your fee changes only when you select it.").font(.caption).foregroundStyle(PaperclipTheme.muted)
        }
    }
    private var makerGuide: some View {
        WalletSection("How earning works") {
            Text("Higher fees can reduce selection. Mining fee contribution: 0 sats.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            Text("A maker offers coins for other people’s CoinJoins and can earn a fee when selected. Keep spendable coins in a jar and your server online. Your phone can close.").font(.subheadline)
            Text("JoinBlaket’s default takers require a fidelity bond. Bond coins remain yours but cannot be spent before the unlock date. They are separate from the coins your maker offers.").font(.subheadline)
            Text("Bond funding is public and can link back to its source. Back up your Jam wallet first; lock only coins you can leave untouched. A bond does not guarantee earnings.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            Text("1. Fund a jar and wait for confirmation. 2. Register a bond address, fund it separately and wait for confirmation. 3. Refresh and review your maker terms.").font(.subheadline)
        }
    }
    private func amountField(_ title: String, text: Binding<String>, accessibility: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(PaperclipTheme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("Amount", text: text).keyboardType(.numberPad).font(.title2.weight(.semibold)).monospacedDigit().accessibilityLabel(accessibility)
                Text("sats").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
            }.padding(16).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.1)))
        }
    }
    private var jarPicker: some View {
        JarGridLayout {
            ForEach(model.jars) { jar in jarCell(jar) }
        }.padding(2).accessibilityElement(children: .contain).accessibilityIdentifier("jar-picker")
    }
    private func jarCell(_ jar: JoinBlaketJar) -> some View {
        let selected = selectedJar == jar.id
        let color = colors[Int(jar.id)]
        let status = jar.pending_sat > 0 ? "Incoming pending" : (selected ? "Selected" : "Jar \(Int(jar.id) + 1)")
        return Button { selectedJar = jar.id; model.address = nil } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    JarIllustration(color: color, funded: jar.total_sat > 0)
                        .scaleEffect(0.45).frame(width: 28, height: 32)
                    Text(jar.name).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
                Text(unit.display(jar.total_sat)).font(.subheadline.monospacedDigit()).foregroundStyle(.primary)
                Text(status)
                    .font(.caption).foregroundStyle(PaperclipTheme.muted)
            }.frame(maxWidth: .infinity, minHeight: 78, alignment: .leading).padding(12)
                .background(color.opacity(selected ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? color : Color.clear, lineWidth: 2))
        }.buttonStyle(WalletNavigationButtonStyle()).accessibilityIdentifier("jar-\(jar.id)").accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var pairingSetup: some View {
        WalletSection("Pair with your server") {
            if let review = pairingReview {
                Text("Server").font(.caption).foregroundStyle(PaperclipTheme.muted)
                Text(review.endpoint).font(.subheadline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                WalletReviewDetail(title: "Jars wallet", value: review.wallet)
                Text(review.canSend ? "Allows managing and sending funds from this Jars wallet for up to 30 days. Review each payment on this phone. Key export and your main wallet are not included." : "Allows balances, receive addresses, maker controls and payment status for up to 30 days. Sending, key export and your main wallet are not included.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                Button("Verify and save connection") {
                    let text = pairingText
                    model.perform { try await model.pair(text); pairingText = ""; pairingReview = nil }
                }.buttonStyle(WalletPrimaryButtonStyle())
                Button("Cancel") { pairingText = ""; pairingReview = nil }.frame(maxWidth: .infinity)
            } else {
                Text("On your host, open Jars → Pair a phone. Scan its private code here.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                Button("Scan pairing code") { scanningPairing = true }.buttonStyle(WalletPrimaryButtonStyle())
                SecureField("Paste pairing code", text: $pairingText).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Review connection") {
                    do { pairingText = pairingText.trimmingCharacters(in: .whitespacesAndNewlines); pairingReview = try JoinBlaketPairing(text: pairingText) }
                    catch { model.message = "Pairing is invalid or expired. Create a new code on your host." }
                }.disabled(pairingText.isEmpty)
                Button("Reconnect saved host") {
                    model.perform {
                        guard let data = try WalletKeychain.read("jars-pairing-v1"), let text = String(data: data, encoding: .utf8) else { throw WalletFailure(message: "No saved Jars pairing on this device.") }
                        try await model.pair(text, save: false)
                    }
                }
                Text("Revoke access from your host’s paired-device list. If Jam locks or restarts, unlock it on the host and create a new pairing.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
        }
    }
    private var makerReadiness: JoinBlaketMakerReadiness {
        JoinBlaketMakerReadiness(minimum: minimum, fee: relativeMode ? "0" : makerFee, jars: model.jars, session: model.session, needsRefresh: model.needsRefresh, relativeFee: relativeMode ? relativeRate : nil)
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
        WalletSection("Set up a fidelity bond") {
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

/// A separate page keeps recovery details out of the compact jars grid.
private struct JoinBlaketRecoveryView: View {
    let load: () async throws -> [JoinBlaketPayment]
    let check: (String) async throws -> JoinBlaketPayment
    var discard: ((String) async throws -> JoinBlaketPayment)? = nil
    @State private var discardID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var payments: [JoinBlaketPayment] = []
    @State private var busy = false
    @State private var loaded = false
    @State private var message: String?
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your Jar transfers, with their latest known status.")
                        .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    if loaded && payments.isEmpty { Text("No saved Paperclip payments in this Jam wallet.") }
                    ForEach(payments) { payment in
                        WalletSection {
                            HStack {
                                Label(payment.state.label, systemImage: payment.needsCheck ? "clock" : "doc.text")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(payment.needsCheck ? PaperclipTheme.orange : PaperclipTheme.muted)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background((payment.needsCheck ? PaperclipTheme.orange : PaperclipTheme.muted).opacity(0.10), in: Capsule())
                            }
                            if let quote = payment.quote {
                                PaymentReviewHero(amount: unit.display(quote.amount_sat),
                                    source: "Jar \(Int(quote.jar) + 1)",
                                    caption: quote.purpose == "send" ? "Payment amount" : quote.purpose == "fund_bond" ? "Bond funding" : "Bond withdrawal")
                                Divider()
                                WalletReviewDetail(title: quote.coinjoin == true ? "Total fees" : "Mining fee", value: unit.display(quote.fee_sat))
                                WalletReviewDetail(title: "Total debit", value: unit.display(quote.total_sat), emphasized: true)
                                DisclosureGroup("Payment details") {
                                    VStack(alignment: .leading, spacing: 12) {
                                        if quote.purpose != "send" { paymentReference("Bond unlock date", value: quote.bondUnlockDescription) }
                                        if quote.coinjoin == true {
                                            WalletReviewDetail(title: "Maker fees", value: unit.display(quote.maker_fee_sat ?? 0))
                                            WalletReviewDetail(title: "Your mining fee", value: unit.display(quote.mining_fee_sat ?? 0))
                                        }
                                        paymentReference("Destination", value: quote.destination)
                                        paymentReference("Transaction ID", value: quote.txid)
                                    }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.subheadline).padding(.vertical, 4)
                            }
                            if payment.needsCheck {
                                Text("This payment may have reached the network. Do not send it again.")
                                    .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                                Button { perform {
                                    let updated = try await check(payment.id)
                                    if let index = payments.firstIndex(where: { $0.id == payment.id }) {
                                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { payments[index] = updated }
                                    }
                                } } label: { Label("Check status", systemImage: "arrow.clockwise") }
                                    .buttonStyle(WalletPrimaryButtonStyle())
                            } else {
                                Text(payment.state == .submitted ? "Seen by your node. Confirmation has not been checked." : "This review has not been sent.")
                                    .font(.footnote).foregroundStyle(PaperclipTheme.muted)
                            }
                            if payment.canDiscard {
                                if discard != nil { Button("Discard review") { discardID = payment.id }.disabled(busy) }
                                else { Text("Discard this unsent review in Jars on your Paperclip host.").font(.footnote).foregroundStyle(PaperclipTheme.muted) }
                            }
                        }
                    }
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    if let message {
                        Label(message, systemImage: "wifi.exclamationmark").font(.subheadline)
                            .foregroundStyle(PaperclipTheme.muted).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(PaperclipTheme.muted.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    }
                }.walletPageContent().disabled(busy)
            }.walletPageBackground().navigationTitle("Jars payments").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("Refresh") { refresh() }.disabled(busy) }
                }
                .confirmationDialog("Discard this unsent review?", isPresented: Binding(get: { discardID != nil }, set: { if !$0 { discardID = nil } }), titleVisibility: .visible) {
                    Button("Discard review", role: .destructive) {
                        guard let id = discardID, let discard else { return }; discardID = nil
                        perform { let updated = try await discard(id); payments = payments.map { $0.id == id ? updated : $0 } }
                    }
                    Button("Keep review", role: .cancel) { discardID = nil }
                } message: { Text("This releases reserved coins without sending a transaction. A submission that has already started cannot be discarded.") }
                .task { refresh() }
        }
    }
    private func paymentReference(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(PaperclipTheme.muted)
            Text(value).font(.footnote.monospaced()).textSelection(.enabled)
        }
    }
    private func refresh() { perform { payments = try await load(); loaded = true } }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        Task { defer { busy = false }; do { try await action() } catch { message = error is JoinBlaketError ? error.localizedDescription : "Could not check payment status. Check your connection and try again." } }
    }
}
