import SwiftUI
import PaperclipMobile

struct CoinjoinView: View {
    @EnvironmentObject var store: WalletStore
    @StateObject private var model = CoinjoinModel()
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @State private var showConnection = false
    @State private var showCreate = false
    @State private var selectedPool: CoinjoinSelection?
    @State private var selectedCoin: CoinjoinSelection?
    @State private var signing: CoinjoinSelection?
    private func amount(_ value: Any?) -> String { unit.display((value as? NSNumber)?.uint64Value) }
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            WalletSection {
                HStack { Label("Coinjoin", systemImage: "shuffle").font(.title2.bold()); Spacer(); Text("Experimental").font(.caption.bold()).foregroundStyle(.orange) }
                Text(amount(model.snapshot["balance_sat"])).font(.largeTitle.bold())
                Text("Separate native SegWit account · same wallet seed and encrypted backup").font(.caption).foregroundStyle(PaperclipTheme.muted)
                Text("Coinjoin does not guarantee anonymity. Peers see inputs and change; the relay may correlate traffic. Tor and separate output connections reduce exposure.").font(.caption)
                HStack {
                    Button("Refresh") { model.perform { try await model.action("coinjoin_sync") } }
                    Spacer()
                    Button(model.connected ? "Relay settings" : "Connect relay") { showConnection = true }
                }
            }
            WalletSection("Receive into Coinjoin") {
                if let address = model.snapshot["address"] as? String {
                    DisclosureGroup("Show receive QR") { ReceiveCode(value: address) }
                    Text(address).font(.caption.monospaced()).textSelection(.enabled)
                    HStack { Button("Copy address") { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: address]], options: [.localOnly: true]) }; Spacer(); Button("New address") { model.perform { try await model.action("coinjoin_address") } } }
                }
                Text("Send only XBT (BLAKE2b). This account stays separate from ordinary on-chain spending. Fund it externally or send from your wallet using this address.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
            if let round = model.active { roundCard(round) }
            WalletSection("Pools") {
                HStack { Text(model.connected ? "Kilojoin v1" : "Relay disconnected").foregroundStyle(PaperclipTheme.muted); Spacer()
                    Button("Create pool") { showCreate = true }.disabled(!model.connected || model.active != nil)
                }
                if model.pools.isEmpty { Text("No open pools loaded. Connect or wait for participants to announce one.").font(.subheadline) }
                ForEach(Array(model.pools.enumerated()), id: \.offset) { _, pool in
                    if let terms = pool["terms"] as? [String: Any] {
                        Button { selectedPool = CoinjoinSelection(value: pool) } label: {
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
            WalletSection("Your coins") {
                Text("Select one coin to prepare an exact amount, withdraw, or board a mixed output into Ark. Paperclip never adds another input to these transfers.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                if model.coins.isEmpty { Text("No unspent coins. Receive XBT above, then refresh.") }
                ForEach(Array(model.coins.enumerated()), id: \.offset) { _, coin in
                    Button { selectedCoin = CoinjoinSelection(value: coin) } label: {
                        HStack { VStack(alignment: .leading, spacing: 4) {
                            Text(amount(coin["amount_sat"])).font(.headline)
                            Text("\((coin["label"] as? String ?? "unmixed").capitalized) · \(coin["confirmed"] as? Bool == true ? "Confirmed" : "Unconfirmed")").font(.caption).foregroundStyle(PaperclipTheme.muted)
                            Text(String((coin["outpoint"] as? String ?? "").prefix(18)) + "…").font(.caption2.monospaced())
                        }; Spacer(); Image(systemName: coin["available"] as? Bool == true ? "chevron.right" : "lock") }
                    }.disabled(coin["available"] as? Bool != true)
                }
            }
            if !model.rounds.isEmpty {
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
            WalletSection("Coinjoin account activity") {
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
            WalletSection("Backup & recovery") {
                NavigationLink("Encrypted wallet backup") { BackupView(engine: store.engine) }
                Button("Scan account from seed") { model.perform { try await model.action("coinjoin_recover") } }
                Text("The seed recovers coins. A full encrypted backup also preserves round state and mixed/change labels. After a seed-only restore, treat recovered coins as having unknown privacy history.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                Text("Hardware and watch-only wallets cannot join v1 pools yet: joining needs custom ownership-proof signatures. Direct boarding inside the Coinjoin transaction is not supported by v1.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
            if model.busy { ProgressView() }
            WalletSection { Text(model.message).font(.subheadline).textSelection(.enabled) }
        }.padding(22) }.background(PaperclipTheme.navy).navigationTitle("Coinjoin").navigationBarTitleDisplayMode(.inline)
            .task { if let id = store.selectedProfile?.id { await model.start(walletID: id) } }
            .onDisappear { model.stop() }
            .sheet(isPresented: $showConnection) { NavigationStack { connection } }
            .sheet(isPresented: $showCreate) { NavigationStack { CoinjoinPoolForm(model: model, pool: nil) } }
            .sheet(item: $selectedPool) { item in NavigationStack { CoinjoinPoolForm(model: model, pool: item.value) } }
            .sheet(item: $selectedCoin) { item in NavigationStack { CoinjoinTransferView(model: model, coin: item.value) } }
            .sheet(item: $signing) { item in NavigationStack { CoinjoinSignView(model: model, round: item.value) } }
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
    @ViewBuilder private func roundCard(_ round: [String: Any]) -> some View {
        let id = round["id"] as? String ?? ""
        let phase = round["phase"] as? String ?? ""
        WalletSection("Current round") {
            Text(phase.capitalized).font(.title2.bold())
            Text("\(amount(round["amount_sat"])) · \(round["peers"] as? Int ?? 0) participants")
            Text("Keep this page open. Leaving the page disconnects; return and connect to resume the saved round.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            if !model.connected { Button("Reconnect round") { model.perform { try await model.connect() } } }
            if phase == "open" { Button("Request close & vote") { model.perform { try await model.action("coinjoin_close", ["id": id]) } } }
            if phase == "voting", round["voted"] as? Bool != true {
                HStack { Button("Accept round") { model.perform { try await model.action("coinjoin_vote", ["id": id, "accept": true]) } }
                    Button("Decline") { model.perform { try await model.action("coinjoin_vote", ["id": id, "accept": false]) } }
                }
            }
            if phase == "signing", round["signed"] as? Bool != true { Button("Review & sign") { signing = CoinjoinSelection(value: round) }.buttonStyle(.borderedProminent) }
            if round["signed"] as? Bool == true { Text("Signature released. This coin stays reserved until the transaction or a conflicting spend is confirmed. A timeout cannot recall a signature.").font(.caption) }
            else { Button("Leave round", role: .destructive) { model.perform { try await model.action("coinjoin_leave", ["id": id]) } } }
            if let deadline = round["deadline"] as? NSNumber, deadline.uint64Value > 0 { Text("Deadline: " + Date(timeIntervalSince1970: deadline.doubleValue).formatted(date: .omitted, time: .standard)).font(.caption) }
            if let txid = round["txid"] as? String { Link("View transaction", destination: URL(string: "https://mempool.guide/tx/" + txid)!) }
            Text(round["reason"] as? String ?? "").font(.caption)
        }.disabled(model.busy)
    }
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
                    TextField("Equal output · " + unit.amountPrompt, text: $amount).keyboardType(.decimalPad)
                    TextField("Fee rate · sat/vB", text: $rate).keyboardType(.decimalPad)
                    Stepper("Minimum \(minimum) participants", value: $minimum, in: 2...20)
                    Stepper("Maximum \(maximum) participants", value: $maximum, in: minimum...20)
                    Stepper("Open for \(hours) hours", value: $hours, in: 1...168)
                    Toggle("Private pool", isOn: $isPrivate)
                } else {
                    LabeledContent("Equal output", value: unit.display(denomination))
                    LabeledContent("Fee rate", value: "\(feeRate) sat/vB")
                    LabeledContent("Participants", value: "\(terms["min_peers"] as? Int ?? 2)–\(terms["max_peers"] as? Int ?? 5)")
                }
                if isPrivate || terms["private"] as? Bool == true { SecureField("Pool password", text: $password) }
            }
            WalletSection("Choose one coin") {
                Picker("Input", selection: $coin) {
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
                Text("Joining reserves the coin and shares its ownership proof. Your final transaction signature still needs a separate review. Change remains linked to your input.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                Button(pool == nil ? "Review new pool" : "Review join") { confirming = true }.buttonStyle(.borderedProminent).disabled(change == nil || model.busy || !model.connected)
            }
            Text(model.message).font(.caption)
        }.padding(22).textFieldStyle(WalletInputStyle()) }.background(PaperclipTheme.navy).navigationTitle(pool == nil ? "Create pool" : "Join pool")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: minimum) { _, n in maximum = max(maximum, n) }
            .confirmationDialog("Reserve this coin and join?", isPresented: $confirming) {
                Button(pool == nil ? "Create experimental pool" : "Join experimental pool") { model.perform {
                    var fields: [String: Any] = ["outpoint": coin, "relay": model.relayURL, "tor": model.useTor, "password": password]
                    if let pool { fields["event"] = pool["event"] }
                    else { fields.merge(["amount_sat": denomination ?? 0, "fee_rate": feeRate, "min_peers": minimum, "max_peers": maximum, "hours": hours, "private": isPrivate]) { _, new in new } }
                    try await model.action(pool == nil ? "coinjoin_create" : "coinjoin_join", fields); password = ""; dismiss()
                } }
            } message: { Text("Equal output: \(unit.display(denomination)). Privacy is experimental. The selected input and change are visible to participants.") }
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
            .confirmationDialog("Release your transaction signature?", isPresented: $confirming) {
                Button("Sign with unified sighash") { model.perform {
                    try await model.action("coinjoin_sign", ["id": round["id"] as? String ?? "", "plan_id": round["plan_id"] as? String ?? ""]); dismiss()
                } }
            }
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
        }.padding(22).textFieldStyle(WalletInputStyle()) }.background(PaperclipTheme.navy).navigationTitle("Coinjoin coin")
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
