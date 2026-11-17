package xyz.paperclip.wallet

import androidx.compose.animation.animateContentSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.foundation.BorderStroke
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.json.JSONObject

/** In-memory only: tab changes retain the server session, never credentials in saved state. */
internal class JoinBlaketUiState {
	val endpoint = mutableStateOf("")
	val pin = mutableStateOf("")
	val tor = mutableStateOf(false)
	val needsRefresh = mutableStateOf(false)
	val wallets = mutableStateOf(emptyList<String>())
	val wallet = mutableStateOf("")
	val client = mutableStateOf<JoinBlaketClient?>(null)
	val authorization = mutableStateOf<JoinBlaketAuthorization?>(null)
	val session = mutableStateOf<JSONObject?>(null)
	val jars = mutableStateOf(emptyList<JSONObject>())
	val selected = mutableIntStateOf(0)
	val address = mutableStateOf<String?>(null)
	val minimum = mutableStateOf("100000")
	val makerFee = mutableStateOf("100")
	val bondMonth = mutableStateOf("")
	val bondAddress = mutableStateOf<String?>(null)
	val paired = mutableStateOf(false)
}

/** The Jam daemon owns these accounts; no local seed or Kilojoin namespace is migrated. */
@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
internal fun JoinBlaketPage(state: JoinBlaketUiState) {
	val context = LocalContext.current
	val uriHandler = LocalUriHandler.current
	val scope = rememberCoroutineScope()
	val unit = LocalBitcoinUnit.current
	var endpoint by state.endpoint
	var pin by state.pin
	var tor by state.tor
	var password by remember { mutableStateOf("") }
	var passphrase by remember { mutableStateOf("") }
	var showPassphrase by remember { mutableStateOf(false) }
	var needsRefresh by state.needsRefresh
	var wallets by state.wallets
	var wallet by state.wallet
	var client by state.client
	var authorization by state.authorization
	var session by state.session
	var jars by state.jars
	var selected by state.selected
	var address by state.address
	var busy by remember { mutableStateOf(false) }
	var message by remember { mutableStateOf<String?>(null) }
	var minimum by state.minimum
	var makerFee by state.makerFee
	var confirmMaker by remember { mutableStateOf(false) }
	var relativeMode by remember { mutableStateOf(false) }
	var relativeRate by remember { mutableStateOf("0.00005") }
	var feeMenu by remember { mutableStateOf(false) }
	var comparisonAmount by remember { mutableStateOf("100000") }
	var showChecks by remember { mutableStateOf(false) }
	var showMarket by remember { mutableStateOf(false) }
	var market by remember { mutableStateOf<JoinBlaketMarket?>(null) }
	var marketUnavailable by remember { mutableStateOf(false) }
	var marketNow by remember { mutableStateOf(java.time.Instant.now().epochSecond) }
	LaunchedEffect(showMarket) { while (showMarket) { marketNow = java.time.Instant.now().epochSecond; kotlinx.coroutines.delay(15_000) } }
	var showMakerGuide by remember { mutableStateOf(false) }
	var showPayments by remember { mutableStateOf(false) }
	var bondMonth by state.bondMonth
	var bondAddress by state.bondAddress
	var showBond by remember { mutableStateOf(false) }
	var reviewedBondMonth by remember { mutableStateOf<String?>(null) }
	var pairingText by remember { mutableStateOf("") }
	var pairingReview by remember { mutableStateOf<JoinBlaketPairing?>(null) }
	var scanningPairing by remember { mutableStateOf(false) }
	var separateJam by remember { mutableStateOf(false) }
	var paired by state.paired
	DisposableEffect(state) {
		onDispose { if (state.authorization.value != null) state.needsRefresh.value = true }
	}
	val colors = listOf(Color(0xFFFF9E54), Color(0xFF7AABFF), Color(0xFFFF777B), Color(0xFFCA9A75), Color(0xFFBF98F4))
	fun run(action: suspend () -> Unit) {
		if (busy) return
		busy = true; message = null
		scope.launch {
			try { action() }
			catch (e: CancellationException) { throw e }
			catch (e: Exception) { message = e.message ?: "Could not reach JoinBlaket" }
			finally { busy = false }
		}
	}
	suspend fun refresh(c: JoinBlaketClient, auth: JoinBlaketAuthorization) {
		needsRefresh = true
		val current = c.status(auth)
		val response = WalletEngine.shared(context).joinBlaketJars(c.coins(auth)).getJSONArray("jars")
		jars = (0 until response.length()).map { response.getJSONObject(it) }
		session = current; needsRefresh = false
	}
	suspend fun pair(text: String, save: Boolean = true) {
		val value = JoinBlaketPairing.parse(text)
		val c = JoinBlaketClient.open(context, value.connection, value); val auth = value.authorization()
		val current = c.status(auth)
		val rows = WalletEngine.shared(context).joinBlaketJars(c.coins(auth)).getJSONArray("jars")
		if (save) SecureStore(context).write("jars-pairing", text.toByteArray())
		client = c; authorization = auth; wallet = value.wallet; session = current
		jars = (0 until rows.length()).map { rows.getJSONObject(it) }; paired = true; needsRefresh = false
		address = null; bondAddress = null; bondMonth = ""; pairingText = ""; pairingReview = null
	}
	if (scanningPairing) QrScanner(onClose = { scanningPairing = false }) { value ->
		try { pairingReview = JoinBlaketPairing.parse(value); pairingText = value; true }
		catch (_: Exception) { message = "Scan a current Paperclip Jars pairing code."; false }
	}
	if (session == null) {
		Text("JoinBlaket", style = MaterialTheme.typography.headlineMedium)
		Text("Pair with Paperclip on your server to manage five jars and earn as a maker.", color = MaterialTheme.colorScheme.onSurfaceVariant)
		CardBlock("Pair with your server") {
			val review = pairingReview
			if (review != null) {
				Text("Server", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
				SelectionContainer { Text(review.endpoint, style = MaterialTheme.typography.bodyMedium) }
				ReviewDetailRow("Jars wallet", review.wallet)
				Text("Allows balances, receive addresses, maker controls and payment status for up to 30 days. Sending, key export and your main wallet are not included.", style = MaterialTheme.typography.bodySmall)
				WalletPrimaryButton(enabled = !busy, modifier = Modifier.fillMaxWidth(), onClick = { run { pair(pairingText) } }) { Text("Verify and save connection") }
				TextButton(enabled = !busy, modifier = Modifier.fillMaxWidth(), onClick = { pairingReview = null; pairingText = "" }) { Text("Cancel") }
			} else {
				Text("On your host, open Jars → Pair a phone. Scan its private code here.", style = MaterialTheme.typography.bodyMedium)
				WalletPrimaryButton(enabled = !busy, modifier = Modifier.fillMaxWidth(), onClick = { scanningPairing = true }) { Text("Scan pairing code") }
				OutlinedTextField(pairingText, { pairingText = it }, label = { Text("Paste pairing code") }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false), enabled = !busy, modifier = Modifier.fillMaxWidth())
				TextButton(enabled = !busy && pairingText.isNotBlank(), onClick = {
					try { pairingText = pairingText.trim(); pairingReview = JoinBlaketPairing.parse(pairingText) }
					catch (_: Exception) { message = "Pairing is invalid or expired. Create a new code on your host." }
				}) { Text("Review connection") }
				TextButton(enabled = !busy, onClick = { run {
					val text = SecureStore(context).read("jars-pairing")?.toString(Charsets.UTF_8) ?: error("No saved Jars pairing on this device.")
					pair(text, save = false)
				} }) { Text("Reconnect saved host") }
				Text("Revoke access from your host’s paired-device list. If Jam locks or restarts, unlock it on the host and create a new pairing.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
			}
		}
		TextButton(enabled = !busy, onClick = { separateJam = !separateJam }) { Text("Connect to a separate Jam server") }
		if (separateJam) {
		TextButton(onClick = { uriHandler.openUri("https://kilombino.com/joinblaket/") }) { Text("Set up Kilombino JoinBlaket") }
		OutlinedTextField(endpoint, { endpoint = it }, label = { Text("HTTPS or onion address") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
		OutlinedTextField(pin, { pin = it }, label = { Text("Certificate SHA256 (optional)") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
		Row { Text("Use Tor", Modifier.weight(1f)); Switch(tor, { tor = it }, enabled = !busy) }
		WalletPrimaryButton(enabled = !busy, onClick = { run {
			authorization = null; jars = emptyList(); address = null; wallets = emptyList(); bondAddress = null; bondMonth = ""; paired = false
			val c = JoinBlaketClient.open(context, JoinBlaketConnection(endpoint.trim(), pin.trim(), if (tor) "builtin" else ""))
			wallets = c.wallets(); wallet = wallets.firstOrNull().orEmpty(); client = c
			if (wallets.isEmpty()) message = "Create a separate wallet in Jam, then refresh this connection."
		} }) { Text("Find wallets") }
		if (wallets.isNotEmpty()) {
			FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				wallets.forEach { name -> FilterChip(selected = wallet == name, onClick = { wallet = name }, label = { Text(name) }, enabled = !busy) }
			}
			OutlinedTextField(password, { password = it }, label = { Text("Jam wallet password") }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false), enabled = !busy, modifier = Modifier.fillMaxWidth())
			TextButton(onClick = { showPassphrase = !showPassphrase }, enabled = !busy) { Text("Wallet passphrase") }
			if (showPassphrase) OutlinedTextField(passphrase, { passphrase = it }, label = { Text("BIP39 passphrase, if used") }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false), enabled = !busy, modifier = Modifier.fillMaxWidth())
			WalletPrimaryButton(enabled = !busy, onClick = {
				val entered = password; val enteredPassphrase = passphrase; password = ""; passphrase = ""
				run { val c = checkNotNull(client); val auth = c.unlock(wallet, entered, enteredPassphrase); authorization = auth; refresh(c, auth) }
			}) { Text("Unlock and view jars") }
		}
		}
	} else {
		WalletSurface {
			Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
				Text("CoinJoin balance", color = MaterialTheme.colorScheme.onSurfaceVariant)
				Text(unit.display(jars.sumOf { it.getLong("total_sat") }), style = MaterialTheme.typography.headlineLarge)
				Text(wallet, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
				if (paired) {
					Text("Paired with your Paperclip host", style = MaterialTheme.typography.bodySmall)
					TextButton(enabled = !busy, onClick = { run {
						SecureStore(context).delete("jars-pairing")
						client = null; authorization = null; session = null; jars = emptyList(); paired = false
						wallet = ""; wallets = emptyList(); address = null; bondAddress = null; bondMonth = ""
					} }) { Text("Forget this connection") }
				}
			}
		}
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
				Text("Your jars", style = MaterialTheme.typography.titleLarge)
				Text("${selected + 1} of 5", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
			}
			TextButton(enabled = !busy, onClick = { run { refresh(checkNotNull(client), checkNotNull(authorization)) } }) { Text("Refresh") }
		}
		BoxWithConstraints(Modifier.fillMaxWidth().padding(2.dp).testTag("jar-picker")) {
			val cardWidth = (maxWidth - 12.dp) / 2
			Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
				jars.chunked(2).forEach { row ->
					Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp, androidx.compose.ui.Alignment.CenterHorizontally)) {
						row.forEach { jar ->
							val id = jar.getInt("id")
							val color = colors[id]
							OutlinedCard(onClick = { selected = id; address = null }, enabled = !busy,
								shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
								modifier = Modifier.width(cardWidth).walletEdgeGlow(color, 20.dp, selected == id && !busy).testTag("jar-$id").semantics { this.selected = selected == id },
								border = BorderStroke(if (selected == id) 2.dp else 1.dp, if (selected == id) color else MaterialTheme.colorScheme.outlineVariant),
								colors = CardDefaults.outlinedCardColors(containerColor = color.copy(alpha = if (selected == id) .20f else .07f))) {
								Column(Modifier.padding(12.dp).heightIn(min = 78.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
									Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
										JamJarArt(color, jar.getLong("total_sat") > 0)
										Text(jar.getString("name"), style = MaterialTheme.typography.titleSmall)
									}
									Text(unit.display(jar.getLong("total_sat")), style = MaterialTheme.typography.bodyMedium)
									Text(if (jar.getLong("pending_sat") > 0) "Incoming pending" else if (selected == id) "Selected" else "Jar ${id + 1}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
								}
							}
						}
					}
				}
			}
		}
		TextButton(enabled = !busy && client != null && authorization != null, onClick = { showPayments = true }) { Text("Jars payment activity") }
		if (showPayments) ModalBottomSheet(onDismissRequest = { showPayments = false }, containerColor = MaterialTheme.colorScheme.background, tonalElevation = 0.dp, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
			Box(Modifier.fillMaxHeight(0.94f)) { JoinBlaketRecoveryPage(checkNotNull(client), checkNotNull(authorization)) { showPayments = false } }
		}
		WalletColumns(primary = {
		jars.firstOrNull { it.getInt("id") == selected }?.let { jar ->
			WalletSurface {
				Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
					Text(jar.getString("name"), style = MaterialTheme.typography.titleLarge)
					for ((field, label) in listOf("confirmed_sat" to "Confirmed", "pending_sat" to "Pending", "frozen_sat" to "Frozen", "bond_sat" to "Fidelity bonds")) {
						val amount = jar.getLong(field)
						if (amount > 0 || field == "confirmed_sat") Row(Modifier.fillMaxWidth()) { Text(label, Modifier.weight(1f)); Text(unit.display(amount)) }
					}
					WalletPrimaryButton(enabled = !busy, onClick = { run { address = checkNotNull(client).receiveAddress(selected, checkNotNull(authorization)) } }) { Text("Receive into ${jar.getString("name")}") }
					address?.let { NodeReceiveCode(it); SelectionContainer { Text(it) } }
				}
			}
		}
		}, secondary = {
		WalletSurface {
			Column(Modifier.padding(18.dp).animateContentSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
				Text("Earn as a maker", style = MaterialTheme.typography.titleMedium)
				Text(if (session?.getBoolean("maker_running") == true) "Running on your server" else "Not running", color = MaterialTheme.colorScheme.onSurfaceVariant)
				Text("Your server can keep making while Paperclip is closed.", color = MaterialTheme.colorScheme.onSurfaceVariant)
				val running = session?.getBoolean("maker_running") == true
				val readiness = JoinBlaketMakerReadiness.evaluate(minimum, if (relativeMode) "0" else makerFee, jars, session, needsRefresh, if (relativeMode) relativeRate else null)
				val minimumValue = minimum.toLongOrNull()
				val feeValue = makerFee.toLongOrNull()

				if (!running) {
					OutlinedTextField(minimum, { minimum = it }, label = { Text("Minimum CoinJoin (sats)") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
					Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
						FilterChip(selected = !relativeMode, enabled = !busy, onClick = { relativeMode = false }, label = { Text("Fixed sats") })
						FilterChip(selected = relativeMode, enabled = !busy, onClick = { relativeMode = true }, label = { Text("Percentage") })
					}
					Box {
						OutlinedButton(enabled = !busy, onClick = { feeMenu = true }) { Text("Your fee: " + if (relativeMode) JoinBlaketMakerFee.label(relativeRate) else "$makerFee sats") }
						DropdownMenu(expanded = feeMenu, onDismissRequest = { feeMenu = false }) {
							if (relativeMode) JoinBlaketMakerFee.rates.forEach { rate -> DropdownMenuItem(text = { Text(JoinBlaketMakerFee.label(rate)) }, onClick = { relativeRate = rate; feeMenu = false }) }
							else JoinBlaketMakerFee.fixed.forEach { fee -> DropdownMenuItem(text = { Text("$fee sats") }, onClick = { makerFee = fee.toString(); feeMenu = false }) }
						}
					}
					if (relativeMode) Text(JoinBlaketMakerFee.example(relativeRate), style = MaterialTheme.typography.bodySmall)
					Text("Your fee is paid to you when selected. Earnings are not guaranteed.", style = MaterialTheme.typography.bodySmall)
					Text(readiness.nextStep, color = if (readiness.canStart) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary)
					TextButton(onClick = { showChecks = !showChecks }) { Text("Setup checks · ${readiness.completedChecks} of 5") }
					if (showChecks) {
					for ((complete, ready, needed) in listOf(
						Triple(readiness.terms, "Amount and fee valid", "Review the minimum amount and fee"),
						Triple(readiness.funds, "One jar covers the minimum", "Fund one jar and wait for confirmation"),
						Triple(readiness.bond, "Bond funds detected", "Set up and fund a fidelity bond"),
						Triple(readiness.server, "Jam is idle", "Wait for Jam to finish syncing or its current operation"),
						Triple(readiness.fresh, "Status refreshed", "Refresh wallet status before continuing"),
					)) {
						Text((if (complete) "Ready: " else "Needed: ") + if (complete) ready else needed,
							color = if (complete) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary)
					}
					}
				}
				if (running && needsRefresh) Text("Refresh maker status before continuing.")
				WalletPrimaryButton(enabled = !busy && !needsRefresh && (running || readiness.canStart), onClick = { confirmMaker = true }) { Text(if (running) "Stop maker" else "Review maker setup") }
				LaunchedEffect(comparisonAmount, client, authorization) { market = null; marketUnavailable = false }
				TextButton(onClick = { showMarket = !showMarket }) { Text("Compare order book fees") }
				if (showMarket) {
					OutlinedTextField(comparisonAmount, { comparisonAmount = it }, label = { Text("Compare CoinJoin amount (sats)") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
					Text("Compare at this CoinJoin amount. One lowest supported offer per verified bonded maker; mining fees are excluded.", style = MaterialTheme.typography.bodySmall)
					market?.let { Text(it.summary(marketNow)); Text("Fetched " + java.time.Instant.ofEpochSecond(it.fetched).atZone(java.time.ZoneId.systemDefault()).toLocalTime().withNano(0), style = MaterialTheme.typography.bodySmall) }
					if (marketUnavailable) Text("Order book unavailable. Your selected fee is unchanged.")
					TextButton(enabled = !busy, onClick = { run {
						market = null; marketUnavailable = false
						try { market = checkNotNull(client).market(comparisonAmount.toLongOrNull() ?: 0, checkNotNull(authorization)) }
						catch (e: CancellationException) { throw e }
						catch (_: Exception) { marketUnavailable = true }
					} }) { Text("Refresh market fees") }
					Text("A market snapshot is not a forecast. Your fee changes only when you select it.", style = MaterialTheme.typography.bodySmall)
				}
				TextButton(onClick = { showMakerGuide = !showMakerGuide }) { Text("How earning and bonds work") }
				if (showMakerGuide) {
					Text("Higher fees can reduce selection. Mining fee contribution: 0 sats.", style = MaterialTheme.typography.bodySmall)
					Text("A maker offers coins for other people’s CoinJoins and can earn a fee when selected. Keep spendable coins in a jar and your server online. Your phone can close.")
					Text("JoinBlaket’s default takers require a fidelity bond. Bond coins remain yours but cannot be spent before the unlock date. They are separate from the coins your maker offers.")
					Text("Bond funding is public and can link back to its source. Back up your Jam wallet first; lock only coins you can leave untouched. A bond does not guarantee earnings.", style = MaterialTheme.typography.bodySmall)
					Text("1. Fund a jar and wait for confirmation. 2. Register a bond address, fund it separately and wait for confirmation. 3. Refresh and review your maker terms.")
				}
				TextButton(enabled = !busy, onClick = { showBond = !showBond }) { Text("Set up a fidelity bond") }
				if (showBond) {
					Text("A bond locks coins until your chosen month. It may help your maker get selected; earnings are not guaranteed.")
					BondMonthPicker(bondMonth, enabled = !busy) { bondMonth = it; bondAddress = null }
					Text("Unlocks on the first day at 00:00 UTC. Creating the address sends no funds.", style = MaterialTheme.typography.bodySmall)
					WalletPrimaryButton(enabled = !busy, onClick = {
						try { JoinBlaketBond.validate(bondMonth); reviewedBondMonth = bondMonth }
						catch (e: Exception) { message = e.message }
					}) { Text("Review bond address") }
					bondAddress?.let {
						Text("Wallet: $wallet · Unlocks $bondMonth-01 at 00:00 UTC.")
						Text("Address ready; no funds sent. Back up your Jam wallet, then review the amount and mining fee in the wallet you fund it from.", style = MaterialTheme.typography.bodySmall)
						NodeReceiveCode(it); SelectionContainer { Text(it) }
					}
				}
				reviewedBondMonth?.let { reviewed ->
					AlertDialog(onDismissRequest = { reviewedBondMonth = null }, title = { Text("Create bond address?") },
						text = { Text("Wallet: $wallet. Coins sent here will be locked until $reviewed-01 at 00:00 UTC. Creating the address sends no funds. Review the amount and mining fee separately when funding. Earnings are not guaranteed.") },
						confirmButton = { TextButton(onClick = {
							reviewedBondMonth = null
							run {
								bondAddress = null
								val result = checkNotNull(client).bondAddress(reviewed, checkNotNull(authorization))
								bondMonth = reviewed; bondAddress = result
							}
						}) { Text("Create address") } },
						dismissButton = { TextButton(onClick = { reviewedBondMonth = null }) { Text("Cancel") } })
				}
				if (confirmMaker) AlertDialog(onDismissRequest = { confirmMaker = false },
					title = { Text(if (running) "Stop your server’s maker?" else "Start making on your Jam server?") },
					text = { Text(if (running) "Existing CoinJoins may need to finish before the maker stops." else "Minimum CoinJoin: $minimum sats. Your fee: ${if (relativeMode) JoinBlaketMakerFee.label(relativeRate) + " of the CoinJoin amount" else "$makerFee sats per CoinJoin"}. Mining fee contribution: 0 sats. The maker uses eligible Jam jars and keeps running when Paperclip closes.") },
					confirmButton = { TextButton(onClick = {
						confirmMaker = false
						run {
							val c = checkNotNull(client); val auth = checkNotNull(authorization)
							needsRefresh = true
							if (running) c.stopMaker(auth) else c.startMaker(checkNotNull(minimumValue), if (relativeMode) 0 else checkNotNull(feeValue), auth, if (relativeMode) relativeRate else null)
							refresh(c, auth)
						}
					}) { Text(if (running) "Stop maker" else "Start maker") } },
					dismissButton = { TextButton(onClick = { confirmMaker = false }) { Text("Cancel") } })
			}
		}
		})
	}
	if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
	message?.let { Text(it) }
}

@Composable private fun BondMonthPicker(value: String, enabled: Boolean, onChange: (String) -> Unit) {
	val currentYear = java.time.YearMonth.now(java.time.ZoneOffset.UTC).year.coerceAtMost(2099)
	val year = value.take(4).toIntOrNull() ?: currentYear
	val month = value.takeLast(2).toIntOrNull() ?: 0
	var monthMenu by remember { mutableStateOf(false) }
	var yearMenu by remember { mutableStateOf(false) }
	val months = java.text.DateFormatSymbols.getInstance().months.take(12)
	Column {
		Box {
			TextButton(enabled = enabled, onClick = { monthMenu = true }) { Text("Unlock month: " + (months.getOrNull(month - 1) ?: "Choose month")) }
			DropdownMenu(expanded = monthMenu, onDismissRequest = { monthMenu = false }) {
				months.forEachIndexed { index, label -> DropdownMenuItem(text = { Text(label) }, onClick = {
					monthMenu = false; onChange("%04d-%02d".format(java.util.Locale.ROOT, year, index + 1))
				}) }
			}
		}
		Box {
			TextButton(enabled = enabled, onClick = { yearMenu = true }) { Text("Unlock year: $year") }
			DropdownMenu(expanded = yearMenu, onDismissRequest = { yearMenu = false }, modifier = Modifier.heightIn(max = 320.dp)) {
				for (option in currentYear..2099) DropdownMenuItem(text = { Text(option.toString()) }, onClick = {
					yearMenu = false; onChange("%04d-%02d".format(java.util.Locale.ROOT, option, month))
				})
			}
		}
	}
}

@Composable private fun JamJarArt(color: Color, funded: Boolean) {
	Canvas(Modifier.size(28.dp, 32.dp)) {
		val width = size.width * .9f; val height = size.height * .875f; val x = (size.width - width) / 2
		drawRoundRect(color.copy(alpha = .08f), Offset(x, 4.dp.toPx()), Size(width, height), CornerRadius(7.dp.toPx()))
		val fill = if (funded) 14.dp.toPx() else 3.dp.toPx()
		drawRoundRect(color.copy(alpha = .35f), Offset(x + 3.dp.toPx(), height - fill), Size(width - 6.dp.toPx(), fill), CornerRadius(4.dp.toPx()))
		drawRoundRect(color.copy(alpha = .65f), Offset(x, 4.dp.toPx()), Size(width, height), CornerRadius(7.dp.toPx()), style = Stroke(1.5.dp.toPx()))
		drawRoundRect(color, Offset(x, 0f), Size(width, 4.dp.toPx()), CornerRadius(4.dp.toPx()))
	}
}

@Composable private fun JoinBlaketRecoveryPage(client: JoinBlaketClient, authorization: JoinBlaketAuthorization, close: () -> Unit) {
	val scope = rememberCoroutineScope()
	val unit = LocalBitcoinUnit.current
	var payments by remember { mutableStateOf<List<JoinBlaketPayment>>(emptyList()) }
	var discardID by remember { mutableStateOf<String?>(null) }
	var loaded by remember { mutableStateOf(false) }
	var busy by remember { mutableStateOf(false) }
	var message by remember { mutableStateOf<String?>(null) }
	fun work(action: suspend () -> Unit) {
		if (busy) return
		busy = true; message = null
		scope.launch {
			try { action() }
			catch (e: CancellationException) { throw e }
			catch (_: Exception) { message = "Could not check payment status. Check your connection and try again." }
			finally { busy = false }
		}
	}
	LaunchedEffect(client, authorization) { work { payments = client.payments(authorization); loaded = true } }
	discardID?.let { id ->
		AlertDialog(onDismissRequest = { discardID = null }, title = { Text("Discard this unsent review?") },
			text = { Text("This releases reserved coins without sending a transaction. A submission that has already started cannot be discarded.") },
			confirmButton = { TextButton(onClick = { discardID = null; work {
				val updated = client.discardPayment(id, authorization)
				payments = payments.map { if (it.id == id) updated else it }
			} }) { Text("Discard review") } },
			dismissButton = { TextButton(onClick = { discardID = null }) { Text("Keep review") } })
	}
	Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
			TextButton(onClick = close) { Text("Done") }
			Text("Jars payments", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
			IconButton(enabled = !busy, onClick = { work { payments = client.payments(authorization); loaded = true } }) { Icon(Icons.Default.Refresh, "Refresh") }
		}
		Text("Your Jar transfers, with their latest known status.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
		if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
		message?.let {
			Surface(color = MaterialTheme.colorScheme.onSurface.copy(alpha = .05f), shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp)) {
				Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
					Icon(Icons.Default.WifiOff, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(20.dp))
					Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
				}
			}
		}
		if (loaded && payments.isEmpty()) Text("No saved Paperclip payments in this Jam wallet.")
		androidx.compose.foundation.lazy.LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false), contentPadding = PaddingValues(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
			items(payments.size, key = { payments[it].id }) { index ->
				val payment = payments[index]
				WalletSurface {
					Column(Modifier.padding(18.dp).animateContentSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
						Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
							Surface(color = MaterialTheme.colorScheme.primary.copy(alpha = .10f), shape = androidx.compose.foundation.shape.CircleShape) {
								Row(Modifier.padding(horizontal = 12.dp, vertical = 7.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
									if (payment.needsCheck) Icon(Icons.Default.Schedule, null, Modifier.size(15.dp), tint = MaterialTheme.colorScheme.primary)
									Text(payment.label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
								}
							}

						}
						payment.quote?.let { quote ->
							ReviewAmountHero(unit.display(quote.amountSat), "Jar ${quote.jar + 1}",
								when (quote.purpose) { "send" -> "Payment amount"; "fund_bond" -> "Bond funding"; else -> "Bond withdrawal" })
							HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
							ReviewDetailRow("Mining fee", unit.display(quote.feeSat))
							ReviewDetailRow("Total debit", unit.display(quote.totalSat), emphasized = true)
							var details by remember(payment.id) { mutableStateOf(false) }
							TextButton(onClick = { details = !details }, modifier = Modifier.fillMaxWidth()) { Text(if (details) "Hide details" else "Payment details") }
							if (details) {
								SelectionContainer {
									Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
										Text("Destination", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
										Text(quote.destination, style = MaterialTheme.typography.bodySmall)
										Text("Transaction ID", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
										Text(quote.txid, style = MaterialTheme.typography.bodySmall)
									}
								}
							}
						}
						if (payment.needsCheck) {
							Text("This payment may have reached the network. Do not send it again.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
							WalletPrimaryButton(modifier = Modifier.fillMaxWidth(), enabled = !busy, onClick = { work {
								val updated = client.checkPayment(payment.id, authorization)
								payments = payments.map { if (it.id == payment.id) updated else it }
							} }) { Icon(Icons.Default.Refresh, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text("Check status") }
						} else {
							Text(if (payment.state == "submitted") "Seen by your node. Confirmation has not been checked." else "This review has not been sent.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
						}
						if (payment.canDiscard) {
							if (client.canDiscardReviews) TextButton(enabled = !busy, onClick = { discardID = payment.id }) { Text("Discard review") }
							else Text("Discard this unsent review in Jars on your Paperclip host.", style = MaterialTheme.typography.bodySmall)
						}
					}
				}
			}
		}
	}
}
