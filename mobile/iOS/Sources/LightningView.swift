import SwiftUI
import PaperclipMobile

struct LightningView: View {
    @AppStorage("displayUnit") private var unit: BitcoinUnit = .sats
    @Environment(\.scenePhase) private var scene
    @State private var busy = false
    @State private var operation = "Working…"
    @State private var connecting = false
    @State private var refreshing = false
    @State private var loadedConfiguration = false
    @State private var savedConnection: LightningConnection?
    @State private var lastChecked: Date?
    @State private var balanceChecked: Date?
    @State private var connectionGeneration = UUID()
    @State private var actionTask: Task<Void, Never>?
    @State private var connectionTask: Task<Void, Error>?
    @State private var message = ""
    @State private var nodeNetwork: LightningNetwork?
    private enum Page: String, Hashable { case balance = "Node balance", connection = "Node connection", receive = "Receive on your node", pay = "Pay from your node", status = "Payment status" }
    @State private var page: Page?
    @State private var scanning = false
    @State private var connection = LightningConnection()
    @State private var client: LightningNode?
    @State private var nodeName = ""
    @State private var connectionError = ""
    @State private var amount = ""
    @State private var receiveInvoice = ""
    @State private var receiveOffer = false
    @State private var offerDescription = "Paperclip wallet"
    @State private var balance: LightningBalance?
    @State private var balanceStatus = ""
    @State private var payInvoice = ""
    @State private var maximumFee = ""
    @State private var payOffer = false
    @State private var offerAmount = ""
    @State private var resolvedInvoice: String?
    @State private var reviewedPayment: LightningPaymentReview?
    @State private var reviewDescription = ""
    @State private var reviewedHash: String?
    @State private var reviewAmount = ""
    @State private var confirming = false
    @State private var receipt: PaymentReceipt?
    @State private var clearingAttempt = false
    @State private var clearingHash: String?
    @ObservedObject private var payments = LightningPaymentMonitor.shared
    @ObservedObject private var bridgeReceives = LightningBridgeReceiveModel.shared
    private var pending: PendingNodePayment? { payments.pending }
    @State private var status = ""
    private let configAccount = "lightning-connection-v1"
    var body: some View {
        ScrollView {
          VStack(spacing: 20) {
            if !connection.endpoint.isEmpty { connectionSummary }
            WalletColumns {
            if client != nil || balance != nil {
                WalletSection {
                    HStack {
                        Label(balance?.activeChannelLocalMsat == nil ? "Available to send" : "Funds in active channels", systemImage: "bolt.fill").foregroundStyle(PaperclipTheme.muted)
                        Spacer()
                        Button { Task { await refreshNode() } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh Lightning balance")
                    }
                    Text(balance.map { unit.display(($0.activeChannelLocalMsat ?? $0.sendableMsat) / 1000) } ?? "—")
                        .font(.system(size: 36, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1).privacySensitive()
                    USDValue(sats: balance.map { ($0.activeChannelLocalMsat ?? $0.sendableMsat) / 1000 }, mainnet: nodeNetwork == .mainnet)
                    if let balance, let funds = balance.activeChannelLocalMsat {
                        LabeledContent("Available to send", value: unit.display(balance.sendableMsat / 1000))
                            .font(.subheadline.weight(.medium))
                        if funds > balance.sendableMsat {
                            Text("Your funds are still in your channels. Channel reserves limit how much you can send.")
                                .font(.caption).foregroundStyle(PaperclipTheme.muted)
                        }
                    } else {
                        Text(balance == nil ? "Balance unavailable · open details to retry" : "Estimated amount available from your node")
                            .font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    }
                    if !balanceStatus.isEmpty {
                        Label(balanceStatus, systemImage: connectionError.isEmpty ? "clock" : "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(PaperclipTheme.muted)
                    }
                    HStack {
                        Button { page = .pay } label: { Label("Pay", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }.modifier(GlassAction())
                        Button { page = .receive } label: { Label("Receive", systemImage: "arrow.down.left").frame(maxWidth: .infinity) }.modifier(GlassAction())
                    }
                    Button { page = .balance } label: {
                        WalletNavigationRow("Balance details", subtitle: "Receive capacity and active channels", icon: "chart.bar")
                    }.buttonStyle(.plain)
                }
            } else {
                WalletSection {
                    Label("Your node. Your Lightning.", systemImage: "bolt.fill").font(.title2.bold())
                    Text("Connect your XBT Core Lightning or LND node to send and receive payments with Paperclip.")
                        .foregroundStyle(PaperclipTheme.muted)
                    Button("Connect a node") { page = .connection }.buttonStyle(WalletPrimaryButtonStyle())
                    if !connectionError.isEmpty { Text(connectionError).font(.caption).foregroundStyle(PaperclipTheme.muted) }
                }
            }
            } secondary: {
            WalletSection("Paperclip Bridge") {
                NavigationLink { LightningBridgeView(source: .node) } label: {
                    WalletNavigationRow("Pay Spamcoin (BTC)", subtitle: "Use XBT through Paperclip Bridge", icon: "arrow.left.arrow.right")
                }.buttonStyle(.plain)
                Divider()
                NavigationLink { LightningBridgeReceiveView() } label: {
                    WalletNavigationRow("Receive from Spamcoin (BTC)", subtitle: "Receive XBT on your CLN or LND node", icon: "arrow.down.left")
                }.buttonStyle(.plain)
            }
            WalletSection {
                Button { page = .connection } label: {
                    WalletNavigationRow(nodeName.isEmpty ? "Node connection" : nodeName,
                        subtitle: client == nil ? "Set up Core Lightning or LND" : connection.implementation.title + (connection.useTor ? " · Tor" : " · Direct connection"), icon: "server.rack")
                }.buttonStyle(.plain)
                Divider()
                Button { page = .status } label: {
                    WalletNavigationRow("Payments", subtitle: pending == nil ? "View your latest payment status" : "Payment in progress · checking automatically", icon: pending == nil ? "clock.arrow.circlepath" : "clock")
                }.buttonStyle(.plain)
            }
            Text("Your node connection is shared across all wallets. Funds and channel backups stay on your node.")
                .font(.caption).foregroundStyle(PaperclipTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            if busy { ProgressView(operation) }
            }
          }.walletPageContent(maxWidth: 1120).textFieldStyle(WalletInputStyle())
        }.navigationTitle("Lightning").walletPageBackground()
            .navigationDestination(item: $page) { selected in
                ScrollView {
                    VStack(spacing: 20) {
                        switch selected {
                        case .balance: balanceCard.disabled(busy)
                        case .connection: connectionCard
                        case .receive: receiveCard.disabled(busy)
                        case .pay: payCard.disabled(busy)
                        case .status: statusCard.disabled(busy)
                        }
                        if busy || !message.isEmpty { WalletSection { if busy { ProgressView(operation) }; Text(message).font(.caption) } }
                    }.walletPageContent(maxWidth: selected == .connection ? 1120 : 680).textFieldStyle(WalletInputStyle())
                }.walletPageBackground().navigationTitle(selected.rawValue).navigationBarTitleDisplayMode(.inline)
            .sheet(item: $receipt) { receipt in
                NavigationStack { PaymentReceiptView(receipt: receipt, amount: reviewedPayment.map { $0.millisatoshis / 1000 }, mainnet: nodeNetwork == .mainnet) { self.receipt = nil; page = nil } }
            }
            .alert("Pay this Lightning invoice?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button("Pay invoice") { pay() }
            } message: { Text("\(reviewAmount)\nMaximum fee: \(maximumFee) \(unit.title)") }
                    .fullScreenCover(isPresented: $scanning) {
                        QRScannerView { value in
                            let normalized = PaymentInput.normalized(value)
                            if normalized.lowercased().hasPrefix("lno1") {
                                payOffer = true; payInvoice = normalized
                            } else if PaymentInput.isBolt11(normalized) || normalized.lowercased().hasPrefix("lni1") {
                                payOffer = false; payInvoice = normalized
                            } else { status = "Scan a Lightning invoice or a BOLT12 offer." }
                        }
                    }
            }
            .task(id: scene) {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("-lightning-balance-preview") || ProcessInfo.processInfo.arguments.contains("-node-connection-preview") { return }
                #endif
                guard scene == .active else { return }
                if !loadedConfiguration { await load() }
                else if !busy && page != .connection { await refreshNode() }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    if !busy && page != .connection { await refreshNode() }
                }
            }
            .onChange(of: bridgeReceives.records.filter(\.received).count) { _, _ in
                Task { await refreshBalance() }
            }
            .onChange(of: payments.completedHash) { _, _ in
                if page == .pay && payments.status == "Payment successful." { receipt = PaymentReceipt(state: "completed") }
                status = payments.status; resolvedInvoice = nil; reviewedHash = nil
                Task { await refreshBalance() }
            }
            .onChange(of: unit) { old, new in
                amount = old.parse(amount).map { new.input($0) } ?? ""
                offerAmount = old.parse(offerAmount).map { new.input($0) } ?? ""
                maximumFee = old.parse(maximumFee).map { new.input($0) } ?? new.input(100)
                reviewedHash = nil; receiveInvoice = ""
            }
            .onChange(of: receiveOffer) { _, _ in receiveInvoice = "" }
            .onChange(of: amount) { _, _ in receiveInvoice = "" }
            .onChange(of: offerDescription) { _, _ in receiveInvoice = "" }
            .onChange(of: payInvoice) { _, value in
                reviewedHash = nil; resolvedInvoice = nil
                let request = PaymentInput.normalized(value).lowercased()
                if request.hasPrefix("lno1") { payOffer = true }
                else if request.hasPrefix("lni1") || PaymentInput.isBolt11(request) { payOffer = false }
            }
            .onChange(of: payOffer) { _, _ in reviewedHash = nil; resolvedInvoice = nil }
            .onChange(of: offerAmount) { _, _ in reviewedHash = nil; resolvedInvoice = nil }
            .onChange(of: maximumFee) { _, _ in reviewedHash = nil }
            .onChange(of: connection) { old, _ in if !old.endpoint.isEmpty { connectionGeneration = UUID(); client = nil; nodeNetwork = nil; reviewedHash = nil; balance = nil; balanceChecked = nil; lastChecked = nil; connectionError = ""; receiveInvoice = ""; receiveOffer = false } }

    }
    private var balanceCard: some View {
        WalletSection("Channel balance") {
            LabeledContent("Available to send", value: balance.map { unit.display($0.sendableMsat / 1000) } ?? "—")
            USDValue(sats: balance.map { $0.sendableMsat / 1000 }, mainnet: nodeNetwork == .mainnet)
            LabeledContent("Receive capacity", value: balance.map { unit.display($0.receivableMsat / 1000) } ?? "—")
            if let balance {
                LabeledContent("Active channels", value: "\(balance.activeChannels)")
                if let funds = balance.activeChannelLocalMsat, let reserve = balance.activeChannelReserveMsat {
                    LabeledContent("Funds in active channels", value: unit.display(funds / 1000))
                    LabeledContent("Required channel reserves", value: unit.display(reserve / 1000))
                    Text("Reserves are required separately in each channel. Funds below a channel’s reserve are held in that channel but cannot be sent. Inactive channels and on-chain funds are not included here.").font(.caption)
                }
            }
            Text("These are estimates. Routes, channel liquidity, and fees can limit individual payments.").font(.caption).foregroundStyle(PaperclipTheme.muted)
            Button("Refresh balance") { Task { await refreshNode() } }.buttonStyle(.bordered)
            if !balanceStatus.isEmpty { Text(balanceStatus).font(.caption).foregroundStyle(PaperclipTheme.muted) }
        }
    }
    private var connectionSummary: some View {
        WalletCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: connecting ? "network" : connectionError.isEmpty && client != nil ? "checkmark.shield.fill" : connectionError.isEmpty ? "server.rack" : "wifi.exclamationmark")
                    .font(.title2).foregroundStyle(connecting ? PaperclipTheme.orange : connectionError.isEmpty && client != nil ? .green : PaperclipTheme.muted)
                VStack(alignment: .leading, spacing: 5) {
                    Text(connecting ? operation : connection != savedConnection ? "Verify your connection" : client != nil && connectionError.isEmpty ? "Node connected" : "Connection needs attention").font(.headline)
                    Text(connection.implementation.title + (connection.useTor ? " · Private route through Tor" : " · Direct HTTPS"))
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                    if let lastChecked { Text("Last verified " + lastChecked.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(PaperclipTheme.muted) }
                }
                Spacer(minLength: 0)
                if connecting || refreshing { ProgressView() }
                else if connection == savedConnection { Button { Task { await refreshNode() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reconnect Lightning node") }
            }
            if !connectionError.isEmpty { Text(connectionError).font(.callout).foregroundStyle(PaperclipTheme.muted) }
            if connecting {
                Button("Cancel connection", role: .cancel) { connectionTask?.cancel(); actionTask?.cancel() }
            }
        }
    }
    private var connectionCard: some View {
        VStack(spacing: 20) {
            connectionSummary
            WalletColumns {
            WalletSection("Your Lightning node") {
                Picker("Node software", selection: $connection.implementation) {
                    ForEach(LightningImplementation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("REST address").font(.subheadline.weight(.semibold))
                    TextField(connection.implementation == .cln ? "https://your-node:3010" : "https://your-node:8180", text: $connection.endpoint)
                        .accessibilityIdentifier("node-rest-address")
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(connection.implementation == .cln ? "Access rune" : "Macaroon (hex)").font(.subheadline.weight(.semibold))
                    SecureField("Saved only on this device", text: $connection.credential).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }.disabled(pending != nil || busy || connecting)
            } secondary: {
            WalletSection("Privacy & verification") {
                Toggle("Connect through Tor", isOn: $connection.useTor)
                if connection.useTor { TorProxyPicker(selection: $connection.torProxy) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Certificate fingerprints · optional").font(.subheadline.weight(.semibold))
                    TextField("SHA256 of the REST certificate", text: $connection.certificateSHA256)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Separate trusted SHA256 fingerprints with commas.")
                        .font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                Label("Credentials stay on this device", systemImage: "lock.shield").font(.caption)
            }.disabled(pending != nil || busy || connecting)
            }
            if pending != nil {
                Text("A payment is being checked. You can reconnect to the saved node; resolve the payment before changing its connection.").font(.callout).foregroundStyle(PaperclipTheme.muted)
                Button("Reconnect saved node") { Task { await refreshNode() } }.buttonStyle(WalletPrimaryButtonStyle()).disabled(connecting || refreshing || busy)
            } else {
                Button("Verify and save connection") { connect() }.buttonStyle(WalletPrimaryButtonStyle()).disabled(busy || connecting)
                if let savedConnection, savedConnection != connection {
                    Button("Restore saved settings") { connection = savedConnection; message = "Saved settings restored. Verify to reconnect." }
                        .buttonStyle(.bordered).disabled(busy || connecting)
                }
            }
        }.scrollDismissesKeyboard(.interactively)
    }
    private var receiveCard: some View {
        WalletSection("Receive on your node") {
                    Picker("Payment request", selection: $receiveOffer) {
                        Text("BOLT11 invoice").tag(false)
                        Text("BOLT12 offer").tag(true)
                    }.pickerStyle(.segmented)
                    Text("Amount in \(unit.title)" + (receiveOffer ? " · optional" : "")).font(.subheadline.weight(.semibold))
                    TextField(receiveOffer ? unit.amountPrompt + " (optional)" : unit.amountPrompt, text: $amount).keyboardType(.decimalPad)
                    if receiveOffer { Text("Offer description").font(.subheadline.weight(.semibold)); TextField("Offer description", text: $offerDescription) }
                    Button(receiveOffer ? "Create BOLT12 offer" : "Create Lightning invoice") { run("Creating payment request…") {
                        guard let client else { return }
                        receiveInvoice = ""
                        if receiveOffer {
                            let sats = amount.isEmpty ? nil : unit.parse(amount)
                            guard amount.isEmpty || (sats != nil && sats! > 0) else { throw WalletFailure(message: "Enter a positive amount, or leave it blank.") }
                            receiveInvoice = try await client.offer(amount: sats, description: offerDescription)
                        } else {
                            guard let sats = unit.parse(amount), sats > 0 else { throw WalletFailure(message: "Enter a positive amount.") }
                            receiveInvoice = try await client.invoice(amount: sats)
                        }
                    } }.buttonStyle(WalletPrimaryButtonStyle())
                    Text(receiveOffer ? "Reusable offer. Your node handles invoice requests and must stay online. Manage saved offers on your node." : "Payments go to your connected Lightning node.").font(.caption)
                    if !receiveInvoice.isEmpty { ReceiveCode(value: receiveInvoice) }
                }
    }
    private var payCard: some View {
        WalletSection("Pay from your node") {
                    if pending != nil {
                        Text("A saved payment needs checking before another can be sent.").font(.headline)
                        Button("View payment status") { page = .status }.buttonStyle(.bordered)
                    }
                    Picker("Payment type", selection: $payOffer) {
                        Text("Invoice").tag(false); Text("BOLT12 offer").tag(true)
                    }.pickerStyle(.segmented).disabled(pending != nil)
                    Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }.disabled(pending != nil)
                    Text(payOffer ? "BOLT12 offer" : "Lightning invoice").font(.subheadline.weight(.semibold))
                    TextField(payOffer ? "BOLT12 offer (lno1…)" : "Lightning invoice", text: $payInvoice, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if payOffer {
                        Text("Review requests an invoice from the offer issuer. No payment is sent until you confirm.").font(.caption)
                        TextField(unit.amountPrompt + " (if needed)", text: $offerAmount)
                            .keyboardType(.decimalPad).accessibilityIdentifier("bolt12-payment-amount")
                        Text("Enter an amount for an amountless offer. Leave blank to use a fixed amount set by the offer.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                    }
                    Text("Maximum routing fee in \(unit.title)").font(.subheadline.weight(.semibold))
                    TextField("Maximum routing fee in \(unit.title)", text: $maximumFee).keyboardType(.decimalPad)
                    Button(payOffer ? "Request invoice & review" : "Review invoice") { review() }.buttonStyle(WalletPrimaryButtonStyle()).disabled(pending != nil || payInvoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if reviewedHash != nil {
                        if !reviewDescription.isEmpty { Text(reviewDescription).font(.subheadline).textSelection(.enabled) }
                        LabeledContent("Amount", value: reviewAmount)
                        LabeledContent("Maximum fee", value: "\(maximumFee) \(unit.title)")
                        Button("Confirm Lightning payment") { confirming = true }.buttonStyle(WalletPrimaryButtonStyle()).disabled(pending != nil)
                    }
                    if pending != nil { Text(payments.status).font(.caption).textSelection(.enabled) }
                    if !status.isEmpty && pending == nil { Text(status).font(.caption).textSelection(.enabled) }
                }
    }
    private var statusCard: some View {
        WalletSection("Payment status") {
                    if let pending { Text("Tracking payment \(pending.hash).").font(.caption.monospaced()) }
                    Text(payments.status.isEmpty ? "No pending outgoing payment from this node." : payments.status).font(.subheadline)
                    Text("This page tracks payments sent from your connected node. For payments sent from Ark, check Activity; receiving an invoice does not create an outgoing payment here.").font(.caption)
                    if payments.checking { ProgressView("Checking with your node…") }
                    if let checked = payments.lastChecked { Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))").font(.caption) }
                    Button("Check now") { Task { await payments.checkNow() } }.disabled(payments.checking || pending == nil)
                    if payments.missingOnNode, let pending {
                        Text("Only clear this attempt after checking that it is not pending or paid on your node. Clearing tracking does not cancel a payment.").font(.caption)
                        Button("Clear saved attempt…") { clearingHash = pending.hash; clearingAttempt = true }
                            .disabled(payments.checking)
                            .confirmationDialog("Have you checked this payment on your node?", isPresented: $clearingAttempt) {
                                Button("I checked: not pending or paid. Clear attempt", role: .destructive) {
                                    do { if let hash = clearingHash { try payments.clearMissingAttempt(hash: hash) } }
                                    catch { message = error.localizedDescription }
                                }
                            } message: { Text("Paperclip will remove the saved attempt. No payment will be sent or retried.") }
                    }
                }
    }
    private func connectionFailure(_ error: Error) -> String {
        if let error = error as? URLError, error.code == .timedOut {
            return connection.useTor
                ? "The node did not respond through Tor. Check its REST address, port, and availability over Tor. Your saved settings have been kept."
                : "The node did not respond. Check its REST address and port, and that this device can reach your node’s network. Your saved settings have been kept."
        }
        if let error = error as? URLError, [.cannotFindHost, .dnsLookupFailed].contains(error.code) {
            return "The node address could not be resolved. Check the hostname and network; .onion addresses require Tor."
        }
        return error.localizedDescription
    }
    private func run(_ label: String = "Working…", _ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; message = ""; operation = label
        actionTask = Task { @MainActor in
            defer { busy = false; actionTask = nil }
            do { try await action() }
            catch is CancellationError { message = label == "Connecting…" ? "Connection check cancelled." : "Request cancelled. Check the saved payment status before trying another payment." }
            catch let error as URLError where error.code == .cancelled { message = label == "Connecting…" ? "Connection check cancelled." : "Request cancelled. Check the saved payment status before trying another payment." }
            catch { message = error.localizedDescription }
        }
    }
    private func load() async {
        if maximumFee.isEmpty { maximumFee = unit.input(100) }
        do {
            if let data = try WalletKeychain.read(configAccount) {
                let stored = try JSONDecoder().decode(LightningConnection.self, from: data)
                connection = stored; savedConnection = stored
            }
            loadedConfiguration = true
            payments.load()
            if !connection.endpoint.isEmpty { try await establish(connection, save: false) }
        } catch {
            if !Task.isCancelled && !(error is CancellationError) && (error as? URLError)?.code != .cancelled { connectionError = connectionFailure(error) }
        }
    }
    private func refreshNode() async {
        guard !busy, !connecting, !refreshing, !connection.endpoint.isEmpty,
              savedConnection == connection else { return }
        if client == nil || !connectionError.isEmpty {
            do { try await establish(connection, save: false) }
            catch { if !Task.isCancelled && !(error is CancellationError) && (error as? URLError)?.code != .cancelled { connectionError = connectionFailure(error) } }
        } else { await refreshBalance() }
    }
    private func refreshBalance() async {
        guard !refreshing, let client else { return }
        refreshing = true; defer { refreshing = false }
        let generation = connectionGeneration
        do {
            let updated = try await client.balance()
            try Task.checkCancellation()
            guard generation == connectionGeneration else { return }
            balance = updated; balanceChecked = Date(); lastChecked = Date(); connectionError = ""
            balanceStatus = "Updated " + Date().formatted(date: .omitted, time: .shortened)
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            connectionError = connectionFailure(error)
            balanceStatus = balanceChecked.map { "Last known balance · " + $0.formatted(date: .omitted, time: .shortened) } ?? "Balance unavailable"
        }
    }
    private func establish(_ selected: LightningConnection, save: Bool) async throws {
        guard !connecting else { return }
        connecting = true; connectionError = ""
        let task = Task { @MainActor in try await establishNode(selected, save: save) }
        connectionTask = task
        defer { connecting = false; connectionTask = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func establishNode(_ selected: LightningConnection, save: Bool) async throws {
        let generation = connectionGeneration
        operation = selected.useTor ? "Connecting through Tor…" : "Contacting your node…"
        var resolved = selected
        try resolved.validate()
        if resolved.useTor { resolved.torProxy = try await EmbeddedTor.shared.proxy(for: resolved.torProxy) }
        try Task.checkCancellation()
        operation = "Verifying node access…"
        let node = try LightningNode(connection: resolved, diagnostics: { event in
            Task { @MainActor in EmbeddedTor.shared.diagnostic("Lightning transport \(event)") }
        })
        let info = try JSONSerialization.jsonObject(with: await node.info()) as? [String: Any] ?? [:]
        let network = try LightningNetwork.decode(info, implementation: selected.implementation)
        let identity = info[selected.implementation == .cln ? "id" : "identity_pubkey"] as? String ?? ""
        guard identity.count == 66, identity.allSatisfy(\.isHexDigit), ["02", "03"].contains(String(identity.prefix(2))) else {
            throw WalletFailure(message: "The node returned an invalid identity. Check its REST endpoint.")
        }
        try Task.checkCancellation()
        guard generation == connectionGeneration, selected == connection else { throw CancellationError() }
        if save { try WalletKeychain.save(JSONEncoder().encode(selected), account: configAccount) }
        savedConnection = selected; nodeNetwork = network; client = node; payments.useNode(node)
        nodeName = info["alias"] as? String ?? selected.implementation.title
        lastChecked = Date(); connectionError = ""
        operation = "Refreshing channel balance…"
        await refreshBalance()
    }
    private func connect() {
        run("Connecting…") {
            guard pending == nil else { throw WalletFailure(message: "Reconcile the saved node payment before changing nodes.") }
            #if DEBUG && targetEnvironment(simulator)
            let persist = !ProcessInfo.processInfo.arguments.contains("-live-node-case")
            #else
            let persist = true
            #endif
            do { try await establish(connection, save: persist) }
            catch {
                if !Task.isCancelled && !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    connectionError = connectionFailure(error)
                    throw WalletFailure(message: connectionError)
                }
                throw error
            }
            if connectionError.isEmpty { page = nil; message = "Lightning node connected." }
        }
    }
    private func review() {
        let request = PaymentInput.normalized(payInvoice), feeText = maximumFee, selectedUnit = unit, chosenAmount = offerAmount
        let isOffer = payOffer || request.lowercased().hasPrefix("lno1")
        run {
            reviewedHash = nil; resolvedInvoice = nil; reviewedPayment = nil; status = ""
            do {
                guard let client, let nodeNetwork, let fee = selectedUnit.parse(feeText), fee <= UInt64.max / 1000,
                      !request.contains(where: \.isWhitespace) else { throw WalletFailure(message: "Enter a Lightning request and a valid fee limit.") }
                var invoice = request
                var expectedMsat: UInt64?
                if isOffer {
                    let offer = try LightningOfferReview.decode(await client.decode(request), implementation: connection.implementation)
                    let entered = chosenAmount.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sats = entered.isEmpty ? nil : selectedUnit.parse(entered)
                    guard entered.isEmpty || sats != nil else {
                        throw WalletFailure(message: "Enter a valid amount in \(selectedUnit.title). XBT supports up to 8 decimal places.")
                    }
                    expectedMsat = try offer.requestedAmount(enteredSats: sats)
                    invoice = try await client.fetchOfferInvoice(request, amountMsat: expectedMsat)
                } else {
                    guard request.lowercased().hasPrefix(nodeNetwork == .mainnet ? "lnbc" : "lnbcrt") ||
                          request.lowercased().hasPrefix("lni1") else {
                        throw WalletFailure(message: "Enter an invoice for this network, or choose BOLT12 offer.")
                    }
                }
                if connection.implementation == .lnd, invoice.lowercased().hasPrefix("lni1") {
                    try LightningNode.validateLNDOfferFee(fee)
                }
                let decoded = try await client.decode(invoice)
                let review = try LightningPaymentReview.decode(decoded, implementation: connection.implementation)
                if let expectedMsat, expectedMsat != review.millisatoshis {
                    throw WalletFailure(message: "The fetched invoice amount differs from the offer or requested amount. No payment was sent.")
                }
                guard request == PaymentInput.normalized(payInvoice), feeText == maximumFee, selectedUnit == unit, chosenAmount == offerAmount else { return }
                let fields = try JSONSerialization.jsonObject(with: decoded) as? [String: Any] ?? [:]
                reviewDescription = fields["offer_description"] as? String ?? (fields["offer"] as? [String: Any])?["description"] as? String ?? fields["description"] as? String ?? ""
                let millis = review.millisatoshis
                reviewAmount = "\(unit.display(millis / 1000))\(millis % 1000 == 0 ? "" : " + \(millis % 1000) msat")"
                resolvedInvoice = invoice; reviewedPayment = review; reviewedHash = review.hash
            } catch { status = error.localizedDescription }
        }
    }
    private func pay() {
        run {
            guard let client, let hash = reviewedHash, let invoice = resolvedInvoice, let reviewedPayment,
                  let fee = unit.parse(maximumFee), pending == nil else { return }
            // Revalidate expiry and bind the saved attempt to the exact reviewed invoice.
            let current = try LightningPaymentReview.decode(await client.decode(invoice), implementation: connection.implementation)
            guard current == reviewedPayment else { throw WalletFailure(message: "Invoice changed or expired. Review again.") }
            let attempt = PendingNodePayment(invoice: invoice, hash: hash)
            try payments.record(attempt)
            reviewedHash = nil
            do {
                let data = try await client.pay(attempt.invoice, maximumFee: fee)
                try payments.submissionResult(data, hash: attempt.hash, implementation: connection.implementation)
                status = payments.pending == nil ? payments.status : "Payment submitted. Checking automatically; you can leave this page."
            } catch {
                if (try? payments.submissionRejected(error, hash: attempt.hash)) == true { status = payments.status }
                else { status = "Payment outcome is not confirmed yet. Paperclip will check automatically without resending." }
            }
            if pending != nil { receipt = PaymentReceipt(state: "pending") }
            payments.submissionFinished()
            Task { await payments.checkNow() }
            if pending == nil { status = payments.status }
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
extension LightningView {
    static func connectionPreview() -> LightningView {
        var view = LightningView()
        view._page = State(initialValue: .connection)
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-live-node-case"), args.indices.contains(index + 1),
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? Data(contentsOf: directory.appendingPathComponent("node-read-probe.json")),
           let input = try? JSONDecoder().decode(NodeReadProbe.Input.self, from: data),
           let selected = input.cases.first(where: { $0.label == args[index + 1] }) {
            view._connection = State(initialValue: selected.connection)
        }
        return view
    }
    static func balancePreview() -> LightningView {
        var view = LightningView()
        let fixture = #"{"channels":[{"active":true,"local_balance":"230000","remote_balance":"49770000","local_chan_reserve_sat":"500000","remote_chan_reserve_sat":"500000"}]}"#
        view._balance = State(initialValue: try! LightningBalance.decode(Data(fixture.utf8), implementation: .lnd))
        return view
    }
}
#endif
