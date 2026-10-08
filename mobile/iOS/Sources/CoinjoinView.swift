import SwiftUI
import PaperclipMobile

struct CoinjoinView: View {
    @EnvironmentObject var store: WalletStore
    @StateObject private var model = CoinjoinModel()
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @State private var showConnection = false
    @State private var page: CoinjoinPage?
    @State private var signing: CoinjoinSelection?
    @State private var upgrading = false
    @State private var leavingRound: String?
    private func amount(_ value: Any?) -> String { unit.display((value as? NSNumber)?.uint64Value) }
    private var availableCoins: Int { model.coins.filter { $0["available"] as? Bool == true }.count }
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection {
                HStack {
                    Label("Coinjoin account", systemImage: "shuffle").font(.headline).foregroundStyle(PaperclipTheme.muted)
                    Spacer()
                    Text("Experimental").font(.caption.bold()).foregroundStyle(PaperclipTheme.orange)
                }
                Text(amount(model.snapshot["balance_sat"])).font(.largeTitle.bold()).contentTransition(.numericText())
                USDValue(sats: (model.snapshot["balance_sat"] as? NSNumber)?.uint64Value, mainnet: store.network == "xbt-mainnet")
                Text("Separate coins. Shared transactions.").foregroundStyle(PaperclipTheme.muted)
                ViewThatFits(in: .horizontal) {
                    HStack { receiveAction; poolsAction }
                    VStack { receiveAction; poolsAction }
                }
                Text("Privacy is experimental and anonymity is not guaranteed.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
            if model.snapshot["legacy_account"] as? Bool == true {
                WalletSection("Separate your Coinjoin account") {
                    Text("Upgrade to a dedicated Coinjoin path. Existing coins will appear in your main SegWit balance; no transaction or fee is involved. Save an updated encrypted backup afterward.").font(.subheadline)
                    Text("Existing mixed coins keep their transaction history. Avoid combining them with other coins if you want to preserve their privacy.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    Button("Upgrade account") { upgrading = true }.disabled(model.busy || model.active != nil)
                    if model.active != nil { Text("Finish the current round and refresh before upgrading.").font(.caption) }
                }
            }
            if let round = model.active { roundCard(round) }
            WalletSection {
                Button { showConnection = true } label: {
                    HStack(spacing: 14) {
                        Circle().fill(model.connected ? Color.green : PaperclipTheme.muted).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.connected ? "Relay connected" : "Relay offline").foregroundStyle(.primary)
                            Text(model.connected ? "Browse pools and keep your round moving" : "Connect when you’re ready to join").font(.caption).foregroundStyle(PaperclipTheme.muted)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption.bold())
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
                pageButton(.coins, subtitle: "\(availableCoins) available · prepare, withdraw, or board into Ark", icon: "circle.grid.2x2")
                Divider()
                pageButton(.activity, subtitle: "Round history and account transactions", icon: "clock.arrow.circlepath")
            }
            WalletSection {
                pageButton(.guide, subtitle: "How it works, privacy, and recovery", icon: "info.circle")
            }
            status
        }.padding(22) }.background(PaperclipTheme.navy).navigationTitle("Coinjoin").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button { model.perform { try await model.action("coinjoin_sync") } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh Coinjoin account").disabled(model.busy)
            } }
            .task { if let id = store.selectedProfile?.id { await model.start(walletID: id) } }
            .onDisappear { model.stop() }
            // Section sheets keep this view mounted and its relay session alive.
            .sheet(item: $page) { destination in
                NavigationStack {
                    ScrollView { VStack(spacing: 20) {
                        switch destination {
                        case .receive: receiveContent
                        case .pools: poolsContent
                        case .coins: coinsContent
                        case .activity: activityContent
                        case .guide: guideContent
                        }
                        status
                    }.padding(22) }.background(PaperclipTheme.navy)
                        .navigationTitle(destination.rawValue).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { page = nil } } }
                }
            }
            .alert("Upgrade Coinjoin account?", isPresented: $upgrading) {
                Button("Upgrade") { model.perform {
                    try await model.action("coinjoin_sync")
                    try await model.action("coinjoin_migrate")
                    model.stop()
                    try await model.action("coinjoin_status")
                    model.message = "Upgraded. Previous coins are available under On-chain → SegWit. Coinjoin now uses account 1. Save a new encrypted backup."
                } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("No coins move on-chain. The old account becomes your main SegWit balance, and new Coinjoin deposits use a separate address account.") }
            .sheet(isPresented: $showConnection) { NavigationStack { connection } }
            .sheet(item: $signing) { item in NavigationStack { CoinjoinSignView(model: model, round: item.value) } }
            .confirmationDialog("Leave this round?", isPresented: Binding(get: { leavingRound != nil }, set: { if !$0 { leavingRound = nil } })) {
                if let id = leavingRound {
                    Button("Leave round", role: .destructive) { model.perform { try await model.action("coinjoin_leave", ["id": id]) }; leavingRound = nil }
                }
            } message: { Text("You’ll stop participating in this round. You can join a different pool afterward.") }
    }
    private var receiveAction: some View {
        Button { page = .receive } label: { Label("Receive", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction())
    }
    private var poolsAction: some View {
        Button { page = .pools } label: { Label("Browse pools", systemImage: "person.2").frame(maxWidth: .infinity) }.modifier(GlassAction())
    }
    private func pageButton(_ destination: CoinjoinPage, subtitle: String, icon: String) -> some View {
        Button { page = destination } label: { WalletNavigationRow(destination.rawValue, subtitle: subtitle, icon: icon) }.buttonStyle(.plain)
    }
    @ViewBuilder private var status: some View {
        if model.busy { ProgressView("Updating Coinjoin…").frame(maxWidth: .infinity) }
        if !model.message.isEmpty {
            Text(model.message).font(.caption).foregroundStyle(PaperclipTheme.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var receiveContent: some View {
        VStack(spacing: 20) {
            WalletSection { WalletBrand(); Text("Fund your Coinjoin account").font(.title2.bold()); Text("Receive XBT here before joining a pool. These coins stay separate from your everyday on-chain balance.").foregroundStyle(PaperclipTheme.muted) }
            WalletSection("Receive into Coinjoin") {
                if let address = model.snapshot["address"] as? String {
                    ReceiveCode(value: address)
                    Button("Generate a new address") { model.perform { try await model.action("coinjoin_address") } }.disabled(model.busy)
                }
                Text("Send only XBT (BLAKE2b). This account stays separate from ordinary on-chain spending. Fund it externally or send from your wallet using this address.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
        }
    }
    private var poolsContent: some View {
            WalletSection("Pools") {
                HStack { Text(model.connected ? "Kilojoin v1" : "Relay disconnected").foregroundStyle(PaperclipTheme.muted); Spacer()
                    NavigationLink("Create pool") { CoinjoinPoolForm(model: model, pool: nil) }.disabled(!model.connected || model.active != nil)
                }
                if !model.connected {
                    Text("Connect to discover pools and their current terms.").foregroundStyle(PaperclipTheme.muted)
                    Button("Connect to relay") { model.perform { try await model.connect() } }.buttonStyle(.borderedProminent).disabled(model.busy)
                } else if model.pools.isEmpty {
                    Label("Waiting for open pools", systemImage: "person.2.wave.2").font(.headline)
                    Text("Pools appear here as they are announced. You can also create one and wait for others to join.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                }
                if model.active != nil { Text("Finish or leave your current round before joining another pool.").font(.caption).foregroundStyle(PaperclipTheme.muted) }
                ForEach(Array(model.pools.enumerated()), id: \.offset) { _, pool in
                    if let terms = pool["terms"] as? [String: Any] {
                        NavigationLink { CoinjoinPoolForm(model: model, pool: pool) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(amount(terms["denomination"])).font(.headline)
                                    Text("\(terms["peers"] as? Int ?? 0)/\(terms["max_peers"] as? Int ?? 0) participants · \(terms["fee_rate"] as? Double ?? 0, specifier: "%g") sat/vB").font(.caption).foregroundStyle(PaperclipTheme.muted)
                                }
                                Spacer(); if terms["private"] as? Bool == true { Image(systemName: "lock") }; Image(systemName: "chevron.right")
                            }.padding(.vertical, 5)
                        }.disabled(model.active != nil)
                    }
                }
            }
    }
    private var coinsContent: some View {
            WalletSection("Your coins") {
                Text("Select one coin to prepare an exact amount, withdraw, or board a mixed output into Ark. Paperclip never adds another input to these transfers.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                if model.coins.isEmpty { Text("No coins yet. Use Receive on the Coinjoin overview to fund this account, then refresh.") }
                ForEach(Array(model.coins.enumerated()), id: \.offset) { _, coin in
                    NavigationLink { CoinjoinTransferView(model: model, coin: coin) } label: {
                        HStack { VStack(alignment: .leading, spacing: 4) {
                            Text(amount(coin["amount_sat"])).font(.headline)
                            Text("\((coin["label"] as? String ?? "unmixed").capitalized) · \(coin["confirmed"] as? Bool == true ? "Confirmed" : "Unconfirmed")").font(.caption).foregroundStyle(PaperclipTheme.muted)
                            if coin["available"] as? Bool != true { Text("Reserved or not yet spendable").font(.caption).foregroundStyle(PaperclipTheme.muted) }
                            Text(String((coin["outpoint"] as? String ?? "").prefix(18)) + "…").font(.caption2.monospaced())
                        }; Spacer(); Image(systemName: coin["available"] as? Bool == true ? "chevron.right" : "lock") }
                    }.disabled(coin["available"] as? Bool != true)
                }
            }
    }
    private var activityContent: some View {
        VStack(spacing: 20) {
            if model.rounds.contains(where: { $0["active"] as? Bool != true }) {
                WalletSection("Round history") {
                    ForEach(Array(model.rounds.filter { $0["active"] as? Bool != true }.enumerated()), id: \.offset) { _, round in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(amount(round["amount_sat"])) · \((round["phase"] as? String ?? "unknown").capitalized)").font(.headline)
                            if let txid = round["txid"] as? String { Link("View transaction", destination: URL(string: "https://mempool.guide/tx/" + txid)!) }
                            Text(round["reason"] as? String ?? "").font(.caption)
                        }
                    }
                }
            }
            WalletSection("Account transactions") {
                if (model.snapshot["activity"] as? [[String: Any]] ?? []).isEmpty {
                    Label("No transactions yet", systemImage: "clock").font(.headline)
                    Text("Deposits, mixes, and transfers for this account appear here.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                }
                ForEach(Array((model.snapshot["activity"] as? [[String: Any]] ?? []).sorted { ($0["timestamp"] as? Int ?? 0) > ($1["timestamp"] as? Int ?? 0) }.enumerated()), id: \.offset) { _, tx in
                    if let txid = tx["txid"] as? String {
                        Link(destination: URL(string: "https://mempool.guide/tx/" + txid)!) {
                            VStack(alignment: .leading) {
                                Text("\((tx["change_sat"] as? Int64 ?? 0) < 0 ? "−" : "+")\(unit.display((tx["change_sat"] as? NSNumber)?.int64Value.magnitude)) · \(tx["confirmed"] as? Bool == true ? "Confirmed" : "Unconfirmed")")
                                Text(String(txid.prefix(20)) + "…").font(.caption.monospaced())
                            }
                        }
                    }
                }
            }
        }
    }
    private var guideContent: some View {
        VStack(spacing: 20) {
            WalletSection("From one coin to a shared transaction") {
                Label("1. Receive or prepare a coin", systemImage: "arrow.down.left")
                Text("Your coin needs to cover the pool amount and your miner fee. Prepare an exact coin from Your coins to avoid linked change.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                Label("2. Choose a pool", systemImage: "person.2")
                Text("Review the amount, fee rate, and participant limits. Joining reserves one coin; you approve the final transaction separately.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                Label("3. Review and sign", systemImage: "signature")
                Text("Keep Coinjoin open during the round. After confirmation, you can withdraw a mixed coin or board it into Ark from Your coins.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
            }
            WalletSection("Understand the privacy limits") {
                Text("Coinjoin does not guarantee anonymity. Peers see inputs and change; the relay may correlate traffic. Tor and separate output connections reduce exposure.")
                Text("Combining mixed coins with other funds can link their histories. Boarding into Ark is a separate, visible on-chain transaction.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
            }
            WalletSection("Backup & recovery") {
                NavigationLink("Encrypted wallet backup") { BackupView(engine: store.engine) }
                Button("Scan account from seed") { model.perform { try await model.action("coinjoin_recover") } }
                Text("The seed recovers coins. A full encrypted backup also preserves round state and mixed/change labels. After a seed-only restore, treat recovered coins as having unknown privacy history.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                Text("Hardware and watch-only wallets cannot join v1 pools yet: joining needs custom ownership-proof signatures. Direct boarding inside the Coinjoin transaction is not supported by v1.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
        }
    }
    private var connection: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection("Relay connection") {
                TextField("wss://relay.kilombino.com", text: $model.relayURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Use built-in Tor", isOn: $model.useTor)
                Text("Everyone in a pool must use the same relay. Active rounds retain their original relay and Tor route.").font(.caption)
                Text("Output posts use a separate connection and fresh Tor isolation credentials. Timing and other network observations can still link activity.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                Button("Connect") { model.perform { try await model.connect(); showConnection = false } }.buttonStyle(.borderedProminent)
            }.disabled(model.busy)
            if model.busy { ProgressView() }; Text(model.message).font(.caption)
        }.padding(22).textFieldStyle(WalletInputStyle()) }.background(PaperclipTheme.navy).navigationTitle("Coinjoin relay")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showConnection = false } } }
    }
    private func roundTitle(_ phase: String) -> String {
        switch phase {
        case "joining": "Joining pool"
        case "open": "Waiting for participants"
        case "voting": "Participant vote"
        case "closing": "Preparing transaction"
        case "signing": "Review and sign"
        case "broadcast": "Waiting for confirmation"
        case "uncertain": "Checking payment outcome"
        default: phase.capitalized
        }
    }
    private func roundHelp(_ phase: String, signed: Bool) -> String {
        if signed { return "Your signature has been shared. Wait for the transaction to confirm; your coin stays reserved." }
        switch phase {
        case "joining": return "Waiting for the pool to accept your ownership proof."
        case "open": return "More people can join. Start a vote when the pool has enough participants."
        case "voting": return "Participants must agree before the transaction is prepared."
        case "closing": return "The agreed inputs and outputs are being collected. No signature is needed yet."
        case "signing": return "Check your output, change, and fee before sharing your signature."
        default: return "Check the round status before making another attempt."
        }
    }
    @ViewBuilder private func roundCard(_ round: [String: Any]) -> some View {
        let id = round["id"] as? String ?? ""
        let phase = round["phase"] as? String ?? ""
        WalletSection("Current round") {
            Text(roundTitle(phase)).font(.title2.bold())
            Text(roundHelp(phase, signed: round["signed"] as? Bool == true)).font(.subheadline).foregroundStyle(PaperclipTheme.muted)
            Text("\(amount(round["amount_sat"])) · \(round["peers"] as? Int ?? 0) participants")
            Text("Keep Coinjoin open while participating. You can browse its pages; leaving Coinjoin disconnects the relay. Reconnect here to resume.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            if !model.connected { Button("Reconnect round") { model.perform { try await model.connect() } } }
            if phase == "open" { Button("Start participant vote") { model.perform { try await model.action("coinjoin_close", ["id": id]) } } }
            if phase == "voting", round["voted"] as? Bool != true {
                HStack { Button("Accept round") { model.perform { try await model.action("coinjoin_vote", ["id": id, "accept": true]) } }
                    Button("Decline") { model.perform { try await model.action("coinjoin_vote", ["id": id, "accept": false]) } }
                }
            }
            if phase == "signing", round["signed"] as? Bool != true { Button("Review & sign") { signing = CoinjoinSelection(value: round) }.buttonStyle(.borderedProminent) }
            if round["signed"] as? Bool == true { Text("Signature released. This coin stays reserved until the transaction or a conflicting spend is confirmed. A timeout cannot recall a signature.").font(.caption) }
            else { Button("Leave round", role: .destructive) { leavingRound = id } }
            if let deadline = round["deadline"] as? NSNumber, deadline.uint64Value > 0 { Text("Deadline: " + Date(timeIntervalSince1970: deadline.doubleValue).formatted(date: .omitted, time: .standard)).font(.caption) }
            if let txid = round["txid"] as? String { Link("View transaction", destination: URL(string: "https://mempool.guide/tx/" + txid)!) }
            Text(round["reason"] as? String ?? "").font(.caption)
        }.disabled(model.busy)
    }
}
private enum CoinjoinPage: String, Identifiable {
    case receive = "Receive XBT", pools = "Pools", coins = "Your coins", activity = "Activity", guide = "Coinjoin guide"
    var id: String { rawValue }
}
struct CoinjoinSelection: Identifiable { let id = UUID(); let value: [String: Any] }

private struct CoinjoinPoolForm: View {
    @ObservedObject var model: CoinjoinModel
    let pool: [String: Any]?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @State private var amount = ""
    @State private var rate = "2"
    @State private var minimum = 2
    @State private var maximum = 5
    @State private var hours = 24
    @State private var isPrivate = false
    @State private var password = ""
    @State private var coin = ""
    @State private var confirming = false
    private var terms: [String: Any] { pool?["terms"] as? [String: Any] ?? [:] }
    private var denomination: UInt64? { pool == nil ? unit.parse(amount) : (terms["denomination"] as? NSNumber)?.uint64Value }
    private var feeRate: Double { pool == nil ? (Double(rate) ?? 0) : ((terms["fee_rate"] as? NSNumber)?.doubleValue ?? 0) }
    private var selected: [String: Any]? { model.coins.first { $0["outpoint"] as? String == coin } }
    private var change: UInt64? {
        guard let d = denomination, let value = (selected?["amount_sat"] as? NSNumber)?.uint64Value, value >= d, feeRate >= 1, feeRate <= 500 else { return nil }
        let excess = value - d, with = UInt64(ceil(feeRate * 135.25)), without = UInt64(ceil(feeRate * 104.25))
        return excess > with + 294 ? excess - with : (excess >= without ? 0 : nil)
    }
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection("Pool terms") {
                if pool == nil {
                    Text("Amount per participant").font(.subheadline.bold())
                    TextField(unit.amountPrompt, text: $amount).keyboardType(.decimalPad)
                    Text("Each participant receives this same amount, before spending it again.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    TextField("Fee rate · sat/vB", text: $rate).keyboardType(.decimalPad)
                    DisclosureGroup("Participants & timing") {
                    Stepper("Minimum \(minimum) participants", value: $minimum, in: 2...20)
                    Stepper("Maximum \(maximum) participants", value: $maximum, in: minimum...20)
                    Stepper("Open for \(hours) hours", value: $hours, in: 1...168)
                    }
                    Toggle("Password-protected pool", isOn: $isPrivate)
                } else {
                    LabeledContent("Equal output", value: unit.display(denomination))
                    LabeledContent("Fee rate", value: "\(feeRate) sat/vB")
                    LabeledContent("Participants", value: "\(terms["min_peers"] as? Int ?? 2)–\(terms["max_peers"] as? Int ?? 5)")
                }
                if isPrivate || terms["private"] as? Bool == true { SecureField("Pool password", text: $password) }
            }
            WalletSection("Choose one coin") {
                Picker("Spendable coin", selection: $coin) {
                    Text("Select a coin").tag("")
                    ForEach(Array(model.coins.filter { $0["available"] as? Bool == true }.enumerated()), id: \.offset) { _, c in
                        Text("\(unit.display((c["amount_sat"] as? NSNumber)?.uint64Value)) · \(c["label"] as? String ?? "unmixed") · \(String((c["outpoint"] as? String ?? "").prefix(8)))").tag(c["outpoint"] as? String ?? "")
                    }
                }
                if let d = denomination, let change, let value = (selected?["amount_sat"] as? NSNumber)?.uint64Value {
                    LabeledContent("Mixed output", value: unit.display(d))
                    LabeledContent("Your miner fee", value: unit.display(value - d - change))
                    LabeledContent("Linked change", value: unit.display(change))
                } else { Text("Select a coin large enough for the denomination and fee.").font(.caption) }
                if model.coins.filter({ $0["available"] as? Bool == true }).isEmpty {
                    Text("No spendable coins yet. Fund your Coinjoin account and wait for confirmation before joining.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                }
                Text("Joining reserves the coin and shares its ownership proof. Your final transaction signature still needs a separate review. Change remains linked to your input.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                Button(pool == nil ? "Review new pool" : "Review join") { confirming = true }.buttonStyle(.borderedProminent).disabled(change == nil || model.busy || !model.connected)
            }
            Text(model.message).font(.caption)
        }.padding(22).textFieldStyle(WalletInputStyle()) }.background(PaperclipTheme.navy).navigationTitle(pool == nil ? "Create pool" : "Join pool").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: minimum) { _, n in maximum = max(maximum, n) }
            .confirmationDialog("Reserve this coin and join?", isPresented: $confirming) {
                Button(pool == nil ? "Create experimental pool" : "Join experimental pool") { model.perform {
                    var fields: [String: Any] = ["outpoint": coin, "relay": model.relayURL, "tor": model.useTor, "password": password]
                    if let pool { fields["event"] = pool["event"] }
                    else { fields.merge(["amount_sat": denomination ?? 0, "fee_rate": feeRate, "min_peers": minimum, "max_peers": maximum, "hours": hours, "private": isPrivate]) { _, new in new } }
                    try await model.action(pool == nil ? "coinjoin_create" : "coinjoin_join", fields); password = ""; dismiss()
                } }
            } message: { Text("Equal output: \(unit.display(denomination)). Linked change: \(unit.display(change)). Privacy is experimental. The selected input and change are visible to participants.") }
    }
}
private struct CoinjoinSignView: View {
    @ObservedObject var model: CoinjoinModel
    let round: [String: Any]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @State private var confirming = false
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection("Review final Coinjoin") {
                ForEach([("Your input", "input"), ("Your equal output", "amount_sat"), ("Your change", "change_sat"), ("Your miner fee", "fee_sat"), ("Whole transaction fee", "total_fee_sat")], id: \.1) { label, key in
                    LabeledContent(label, value: unit.display((round[key] as? NSNumber)?.uint64Value))
                }
                Text("Transaction ID").font(.caption.bold())
                Text(round["plan_id"] as? String ?? "").font(.caption.monospaced()).textSelection(.enabled)
                Text("Paperclip verifies every input against your chain backend, the agreed outputs and fees, and signs only your input with unified sighash 0x21. Once shared, your signature cannot be recalled.").font(.subheadline)
                Button("Approve & share signature") { confirming = true }.buttonStyle(.borderedProminent).disabled(model.busy || !model.connected)
            }
            Text(model.message).font(.caption)
        }.padding(22) }.background(PaperclipTheme.navy).navigationTitle("Sign Coinjoin")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Release your transaction signature?", isPresented: $confirming) {
                Button("Sign transaction") { model.perform {
                    try await model.action("coinjoin_sign", ["id": round["id"] as? String ?? "", "plan_id": round["plan_id"] as? String ?? ""]); dismiss()
                } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Sign with unified sighash 0x21 and share with this pool. Once shared, your signature cannot be recalled.") }
    }
}
private struct CoinjoinTransferView: View {
    @ObservedObject var model: CoinjoinModel
    let coin: [String: Any]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @State private var action = "withdraw"
    @State private var destination = ""
    @State private var amount = ""
    @State private var rate = "2"
    @State private var quote: [String: Any]?
    @State private var confirming = false
    @State private var submitted = false
    @State private var unmixedConfirmed = false
    private var mixed: Bool { coin["label"] as? String == "mixed" }
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection("One coin · one transfer") {
                Text(unit.display((coin["amount_sat"] as? NSNumber)?.uint64Value)).font(.title.bold())
                Picker("Action", selection: $action) {
                    Text("Withdraw").tag("withdraw")
                    if mixed { Text("Board into Ark").tag("board") } else { Text("Prepare exact coin").tag("exact") }
                }
                if action == "withdraw" { TextField("Destination XBT address", text: $destination, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled() }
                if action == "exact" {
                    TextField("Pool denomination · " + unit.amountPrompt, text: $amount).keyboardType(.decimalPad)
                    TextField("Pool fee rate · sat/vB", text: $rate).keyboardType(.decimalPad)
                    Toggle("This source coin is unmixed", isOn: $unmixedConfirmed)
                    Text("The new coin includes the pool’s no-change fee share. This preparation transaction has a separate network fee.").font(.caption)
                }
                if action == "board" { Text("Board this mixed output alone. No unrelated coins are added. Ark recovery funding is deducted after the on-chain fee, and Ark funds remain protected by this mobile wallet’s keys. The separate boarding transaction remains visible on-chain.").font(.caption) }
                Button("Review transfer") { model.perform {
                    var fields: [String: Any] = ["action": action, "outpoint": coin["outpoint"] as? String ?? "", "destination": destination]
                    if action == "exact" {
                        guard let sats = unit.parse(amount), (10000...100000000).contains(sats), let feeRate = Double(rate), feeRate.isFinite, (1...500).contains(feeRate) else { throw WalletFailure(message: "Enter a denomination from 10,000 to 100,000,000 sats and a fee rate from 1 to 500.") }
                        fields["amount_sat"] = sats + UInt64(ceil(feeRate * 104.25)); fields["unmixed_confirmed"] = unmixedConfirmed
                    }
                    quote = try await model.call("coinjoin_quote", fields)
                } }.buttonStyle(.borderedProminent)
            }.disabled(model.busy || submitted)
            if let quote {
                WalletSection("Review") {
                    Text(quote["destination"] as? String ?? "").font(.caption.monospaced()).textSelection(.enabled)
                    LabeledContent("Source coin", value: unit.display((quote["input_sat"] as? NSNumber)?.uint64Value))
                    LabeledContent("Change", value: unit.display((quote["change_sat"] as? NSNumber)?.uint64Value))
                    LabeledContent("Recipient amount", value: unit.display((quote["amount_sat"] as? NSNumber)?.uint64Value))
                    LabeledContent("Network fee", value: unit.display((quote["fee_sat"] as? NSNumber)?.uint64Value))
                    if action == "board" {
                        LabeledContent("Recovery funding · deducted", value: unit.display((quote["reserve_sat"] as? NSNumber)?.uint64Value))
                        LabeledContent("Spendable in Ark", value: unit.display((quote["net_sat"] as? NSNumber)?.uint64Value))
                    }
                    Button("Confirm transfer") { confirming = true }.buttonStyle(.borderedProminent).disabled(model.busy || submitted)
                }
            }
            Text(model.message).font(.caption)
        }.padding(22).textFieldStyle(WalletInputStyle()) }.background(PaperclipTheme.navy).navigationTitle("Manage coin").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: action) { _, _ in quote = nil }.onChange(of: amount) { _, _ in quote = nil }.onChange(of: rate) { _, _ in quote = nil }.onChange(of: destination) { _, _ in quote = nil }
            .confirmationDialog("Send this single-coin transfer?", isPresented: $confirming) {
                Button("Confirm and send") { model.perform {
                    submitted = true
                    try await model.action("coinjoin_transfer", ["quote_id": quote?["quote_id"] as? String ?? ""])
                    model.message = "Transfer saved. Refresh to check confirmation; save an updated encrypted backup."; dismiss()
                } }
            }
    }
}
