package xyz.paperclip.wallet

import androidx.compose.foundation.BorderStroke
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
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
	var showPayments by remember { mutableStateOf(false) }
	var bondMonth by state.bondMonth
	var bondAddress by state.bondAddress
	var showBond by remember { mutableStateOf(false) }
	var reviewedBondMonth by remember { mutableStateOf<String?>(null) }
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
	if (session == null) {
		Text("JoinBlaket", style = MaterialTheme.typography.headlineMedium)
		Text("Connect your Jam server to manage five separate jars and run a maker.", color = MaterialTheme.colorScheme.onSurfaceVariant)
		TextButton(onClick = { uriHandler.openUri("https://kilombino.com/joinblaket/") }) { Text("Set up Kilombino JoinBlaket") }
		OutlinedTextField(endpoint, { endpoint = it }, label = { Text("HTTPS or onion address") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
		OutlinedTextField(pin, { pin = it }, label = { Text("Certificate SHA256 (optional)") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
		Row { Text("Use Tor", Modifier.weight(1f)); Switch(tor, { tor = it }, enabled = !busy) }
		WalletPrimaryButton(enabled = !busy, onClick = { run {
			authorization = null; jars = emptyList(); address = null; wallets = emptyList(); bondAddress = null; bondMonth = ""
			val c = JoinBlaketClient.open(context, JoinBlaketConnection(endpoint.trim(), pin.trim(), if (tor) "builtin" else ""))
			wallets = c.wallets(); wallet = wallets.firstOrNull().orEmpty(); client = c
			if (wallets.isEmpty()) message = "Create a separate wallet in Jam, then refresh this connection."
		} }) { Text("Find wallets") }
		if (wallets.isNotEmpty()) {
			FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				wallets.forEach { name -> FilterChip(selected = wallet == name, onClick = { wallet = name }, label = { Text(name) }, enabled = !busy) }
			}
			OutlinedTextField(password, { password = it }, label = { Text("Jam wallet password") }, visualTransformation = PasswordVisualTransformation(), enabled = !busy, modifier = Modifier.fillMaxWidth())
			TextButton(onClick = { showPassphrase = !showPassphrase }, enabled = !busy) { Text("Wallet passphrase") }
			if (showPassphrase) OutlinedTextField(passphrase, { passphrase = it }, label = { Text("BIP39 passphrase, if used") }, visualTransformation = PasswordVisualTransformation(), enabled = !busy, modifier = Modifier.fillMaxWidth())
			WalletPrimaryButton(enabled = !busy, onClick = {
				val entered = password; val enteredPassphrase = passphrase; password = ""; passphrase = ""
				run { val c = checkNotNull(client); val auth = c.unlock(wallet, entered, enteredPassphrase); authorization = auth; refresh(c, auth) }
			}) { Text("Unlock and view jars") }
		}
	} else {
		WalletSurface {
			Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
				Text("CoinJoin balance", color = MaterialTheme.colorScheme.onSurfaceVariant)
				Text(unit.display(jars.sumOf { it.getLong("total_sat") }), style = MaterialTheme.typography.headlineLarge)
				Text(wallet, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
		if (showPayments) ModalBottomSheet(onDismissRequest = { showPayments = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
			JoinBlaketRecoveryPage(checkNotNull(client), checkNotNull(authorization))
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
		Text(if (session?.getBoolean("maker_running") == true) "Maker running on your server" else "Maker not running", style = MaterialTheme.typography.titleMedium)
		Text("Your server can keep making while Paperclip is closed.", color = MaterialTheme.colorScheme.onSurfaceVariant)
		val running = session?.getBoolean("maker_running") == true
		val readiness = JoinBlaketMakerReadiness.evaluate(minimum, makerFee, jars, session, needsRefresh)
		val minimumValue = minimum.toLongOrNull()
		val feeValue = makerFee.toLongOrNull()

		if (!running) {
			OutlinedTextField(minimum, { minimum = it }, label = { Text("Minimum CoinJoin (sats)") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
			OutlinedTextField(makerFee, { makerFee = it }, label = { Text("Your fee per CoinJoin (sats)") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
			Text("Mining fee contribution: 0 sats. Earnings depend on being selected.")
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
			Text("Your server checks final eligibility; earnings are not guaranteed.", style = MaterialTheme.typography.bodySmall)
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
		if (needsRefresh) Text("Refresh maker status before another action.")
		WalletPrimaryButton(enabled = !busy && !needsRefresh && (running || readiness.canStart), onClick = { confirmMaker = true }) { Text(if (running) "Stop maker" else "Review maker setup") }
		if (confirmMaker) AlertDialog(onDismissRequest = { confirmMaker = false },
			title = { Text(if (running) "Stop your server’s maker?" else "Start making on your Jam server?") },
			text = { Text(if (running) "Existing CoinJoins may need to finish before the maker stops." else "Minimum CoinJoin: $minimum sats. Your fee: $makerFee sats per CoinJoin. Mining fee contribution: 0 sats. The maker uses eligible Jam jars and keeps running when Paperclip closes.") },
			confirmButton = { TextButton(onClick = {
				confirmMaker = false
				run {
					val c = checkNotNull(client); val auth = checkNotNull(authorization)
					needsRefresh = true
					if (running) c.stopMaker(auth) else c.startMaker(checkNotNull(minimumValue), checkNotNull(feeValue), auth)
					refresh(c, auth)
				}
			}) { Text(if (running) "Stop maker" else "Start maker") } },
			dismissButton = { TextButton(onClick = { confirmMaker = false }) { Text("Cancel") } })
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

@Composable private fun JoinBlaketRecoveryPage(client: JoinBlaketClient, authorization: JoinBlaketAuthorization) {
	val scope = rememberCoroutineScope()
	val unit = LocalBitcoinUnit.current
	var payments by remember { mutableStateOf<List<JoinBlaketPayment>>(emptyList()) }
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
	Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
			Text("Jars payments", style = MaterialTheme.typography.titleLarge)
			TextButton(enabled = !busy, onClick = { work { payments = client.payments(authorization); loaded = true } }) { Text("Refresh") }
		}
		Text("Saved payments from your separate Jam wallet. Checking status never sends again.", style = MaterialTheme.typography.bodyMedium)
		if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
		message?.let { Text(it) }
		if (loaded && payments.isEmpty()) Text("No saved Paperclip payments in this Jam wallet.")
		androidx.compose.foundation.lazy.LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false), contentPadding = PaddingValues(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
			items(payments.size, key = { payments[it].id }) { index ->
				val payment = payments[index]
				WalletSurface {
					Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
						Text(payment.label, style = MaterialTheme.typography.titleMedium)
						payment.quote?.let { quote ->
							Text(unit.display(quote.amountSat), style = MaterialTheme.typography.headlineSmall)
							Text("Jar "+(quote.jar + 1)+" · "+when (quote.purpose) { "send" -> "Send"; "fund_bond" -> "Bond funding"; else -> "Bond withdrawal" })
							var details by remember(payment.id) { mutableStateOf(false) }
							TextButton(onClick = { details = !details }) { Text(if (details) "Hide details" else "Payment details") }
							if (details) {
								Text("Mining fee: " + unit.display(quote.feeSat)); Text("Total: " + unit.display(quote.totalSat))
								SelectionContainer { Column { Text(quote.destination); Text("Transaction: " + quote.txid) } }
							}
						}
						if (payment.needsCheck) {
							Text("This payment may have reached the network. Do not send it again.")
							WalletPrimaryButton(enabled = !busy, onClick = { work {
								val updated = client.checkPayment(payment.id, authorization)
								payments = payments.map { if (it.id == payment.id) updated else it }
							} }) { Text("Check status") }
						}
					}
				}
			}
		}
	}
}
