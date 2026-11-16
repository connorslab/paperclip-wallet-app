package xyz.paperclip.wallet

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

/** The Jam daemon owns these accounts; no local seed or Kilojoin namespace is migrated. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun JoinBlaketPage(onLegacy: () -> Unit) {
	val context = LocalContext.current
	val uriHandler = LocalUriHandler.current
	val scope = rememberCoroutineScope()
	val unit = LocalBitcoinUnit.current
	var endpoint by remember { mutableStateOf("") }
	var pin by remember { mutableStateOf("") }
	var tor by remember { mutableStateOf(false) }
	var password by remember { mutableStateOf("") }
	var passphrase by remember { mutableStateOf("") }
	var showPassphrase by remember { mutableStateOf(false) }
	var needsRefresh by remember { mutableStateOf(false) }
	var wallets by remember { mutableStateOf(emptyList<String>()) }
	var wallet by remember { mutableStateOf("") }
	var client by remember { mutableStateOf<JoinBlaketClient?>(null) }
	var authorization by remember { mutableStateOf<JoinBlaketAuthorization?>(null) }
	var session by remember { mutableStateOf<JSONObject?>(null) }
	var jars by remember { mutableStateOf(emptyList<JSONObject>()) }
	var selected by remember { mutableIntStateOf(0) }
	var address by remember { mutableStateOf<String?>(null) }
	var busy by remember { mutableStateOf(false) }
	var message by remember { mutableStateOf<String?>(null) }
	var minimum by remember { mutableStateOf("100000") }
	var makerFee by remember { mutableStateOf("100") }
	var confirmMaker by remember { mutableStateOf(false) }
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
	Text("JoinBlaket", style = MaterialTheme.typography.headlineMedium)
	if (session == null) {
		Text("Connect your Jam server to manage five separate jars and run a maker.", color = MaterialTheme.colorScheme.onSurfaceVariant)
		TextButton(onClick = { uriHandler.openUri("https://kilombino.com/joinblaket/") }) { Text("Set up Kilombino JoinBlaket") }
		OutlinedTextField(endpoint, { endpoint = it }, label = { Text("HTTPS or onion address") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
		OutlinedTextField(pin, { pin = it }, label = { Text("Certificate SHA256 (optional)") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
		Row { Text("Use Tor", Modifier.weight(1f)); Switch(tor, { tor = it }, enabled = !busy) }
		Button(enabled = !busy, onClick = { run {
			authorization = null; jars = emptyList(); address = null; wallets = emptyList()
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
			Button(enabled = !busy, onClick = {
				val entered = password; val enteredPassphrase = passphrase; password = ""; passphrase = ""
				run { val c = checkNotNull(client); val auth = c.unlock(wallet, entered, enteredPassphrase); authorization = auth; refresh(c, auth) }
			}) { Text("Unlock and view jars") }
		}
	} else {
		Text("CoinJoin balance", color = MaterialTheme.colorScheme.onSurfaceVariant)
		Text(unit.display(jars.sumOf { it.getLong("total_sat") }), style = MaterialTheme.typography.headlineLarge)
		Text(wallet, color = MaterialTheme.colorScheme.onSurfaceVariant)
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
			Text("Your jars", style = MaterialTheme.typography.titleLarge)
			TextButton(enabled = !busy, onClick = { run { refresh(checkNotNull(client), checkNotNull(authorization)) } }) { Text("Refresh") }
		}
		FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
			jars.forEach { jar ->
				val id = jar.getInt("id")
				val color = colors[id]
				OutlinedCard(onClick = { selected = id; address = null }, enabled = !busy,
					modifier = Modifier.widthIn(min = 145.dp, max = 210.dp),
					colors = CardDefaults.outlinedCardColors(containerColor = color.copy(alpha = if (selected == id) .20f else .07f))) {
					Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
						JamJarArt(color, jar.getLong("total_sat") > 0)
						Text(jar.getString("name"), style = MaterialTheme.typography.titleMedium)
						Text(unit.display(jar.getLong("total_sat")))
					}
				}
			}
		}
		WalletColumns(primary = {
		jars.firstOrNull { it.getInt("id") == selected }?.let { jar ->
			Card(Modifier.fillMaxWidth()) {
				Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
					Text(jar.getString("name"), style = MaterialTheme.typography.titleLarge)
					for ((field, label) in listOf("confirmed_sat" to "Confirmed", "pending_sat" to "Pending", "frozen_sat" to "Frozen", "bond_sat" to "Fidelity bonds")) {
						val amount = jar.getLong(field)
						if (amount > 0 || field == "confirmed_sat") Row(Modifier.fillMaxWidth()) { Text(label, Modifier.weight(1f)); Text(unit.display(amount)) }
					}
					Button(enabled = !busy, onClick = { run { address = checkNotNull(client).receiveAddress(selected, checkNotNull(authorization)) } }) { Text("Receive into ${jar.getString("name")}") }
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
			if (!readiness.bond) {
				Text("Set up a fidelity bond in Jam. Bond funds stay locked until the date you choose; they are separate from the coins your maker offers.")
				val server = runCatching { java.net.URI(endpoint.trim()) }.getOrNull()
				if (server?.scheme == "https" && server.host?.endsWith(".onion") == false) {
					TextButton(onClick = { uriHandler.openUri(server.toString()) }) { Text("Open Jam to set up your bond") }
				} else {
					Text("Open your Jam address in a Tor browser, then refresh your jars here.")
					SelectionContainer { Text(endpoint) }
				}
			}
			for ((complete, ready, needed) in listOf(
				Triple(readiness.terms, "Amount and fee valid", "Review the minimum amount and fee"),
				Triple(readiness.funds, "One jar covers the minimum", "Fund one jar and wait for confirmation"),
				Triple(readiness.bond, "Bond funds detected", "Set up a JoinBlaket fidelity bond in Jam"),
				Triple(readiness.server, "Jam is idle", "Wait for Jam to finish syncing or its current operation"),
				Triple(readiness.fresh, "Status refreshed", "Refresh wallet status before continuing"),
			)) {
				Text((if (complete) "Ready: " else "Needed: ") + if (complete) ready else needed,
					color = if (complete) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary)
			}
			Text("Your server checks final eligibility; earnings are not guaranteed.", style = MaterialTheme.typography.bodySmall)
		}
		if (needsRefresh) Text("Refresh maker status before another action.")
		Button(enabled = !busy && !needsRefresh && (running || readiness.canStart), onClick = { confirmMaker = true }) { Text(if (running) "Stop maker" else "Review maker setup") }
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
	TextButton(onClick = onLegacy, enabled = !busy) { Text("Previous Kilojoin funds and round recovery") }
}

@Composable private fun JamJarArt(color: Color, funded: Boolean) {
	Canvas(Modifier.fillMaxWidth().height(70.dp)) {
		val width = 56.dp.toPx(); val height = 62.dp.toPx(); val x = (size.width - width) / 2
		drawRoundRect(color.copy(alpha = .08f), Offset(x, 6.dp.toPx()), Size(width, height), CornerRadius(14.dp.toPx()))
		val fill = if (funded) 30.dp.toPx() else 4.dp.toPx()
		drawRoundRect(color.copy(alpha = .35f), Offset(x + 5.dp.toPx(), height - fill), Size(width - 10.dp.toPx(), fill), CornerRadius(8.dp.toPx()))
		drawRoundRect(color.copy(alpha = .65f), Offset(x, 6.dp.toPx()), Size(width, height), CornerRadius(14.dp.toPx()), style = Stroke(2.dp.toPx()))
		drawRoundRect(color, Offset(x, 0f), Size(width, 7.dp.toPx()), CornerRadius(4.dp.toPx()))
	}
}
