package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
internal fun BridgePage(model: BridgeModel, canUseArk: Boolean) {
	val state by model.state.collectAsStateWithLifecycle()
	LaunchedEffect(model) { model.load() }
	DisposableEffect(model) { onDispose { model.invalidateReview() } }
	BridgeContent(state, canUseArk, { direction -> BridgeStatusBadge(model, direction) },
		model::quote, model::fund, model::check, model::saveKey, model::selectSaved)
}

/** Separate entry, review, activity and access pages keep payment authorization explicit. */
@Composable
internal fun BridgeContent(
	s: BridgeState,
	canUseArk: Boolean,
	status: @Composable (Boolean?) -> Unit,
	onQuote: (String, String, Boolean, String, String) -> Unit,
	onFund: () -> Unit,
	onCheck: () -> Unit,
	onSaveKey: (String) -> Unit,
	onSelect: (String) -> Unit,
) {
	val unit = LocalBitcoinUnit.current
	val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
	var page by remember { mutableStateOf("home") }
	var motionDirection by remember { mutableIntStateOf(1) }
	var source by remember { mutableStateOf("node") }
	var invoice by remember { mutableStateOf("") }
	var amount by remember { mutableStateOf("") }
	var fee by remember { mutableStateOf(unit.input(100)) }
	var key by remember { mutableStateOf("") }
	var selected by remember { mutableStateOf<String?>(null) }
	var observedQuote by remember { mutableLongStateOf(s.quoteRevision) }
	var details by remember { mutableStateOf(false) }
	var historyPage by remember { mutableIntStateOf(0) }
	var now by remember { mutableLongStateOf(System.currentTimeMillis() / 1000) }
	val heading = remember { androidx.compose.foundation.relocation.BringIntoViewRequester() }
	fun navigate(value: String) { motionDirection = if (value == "home" || (page == "detail" && value == "pay")) -1 else 1; page = value; details = false; key = "" }
	fun openRecord(record: org.json.JSONObject) {
		selected = record.getString("hash"); onSelect(checkNotNull(selected)); navigate("detail")
	}
	LaunchedEffect(s.quoteRevision) {
		if (observedQuote != s.quoteRevision) {
			observedQuote = s.quoteRevision; selected = s.record?.optString("hash"); navigate("detail")
		}
	}
	LaunchedEffect(page) {
		heading.bringIntoView()
		while (page == "detail") { now = System.currentTimeMillis() / 1000; delay(1000) }
	}
	androidx.activity.compose.BackHandler(page != "home") { if (!s.busy) navigate("home") }
	val current = s.record?.takeIf { it.optString("hash") == selected }
	val receive = when (page) { "pay" -> false; "receive" -> true; "detail" -> current?.optBoolean("receive"); else -> null }
	Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
		Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
			if (page != "home") TextButton(onClick = { navigate("home") }, enabled = !s.busy) { Text("Back to bridge") }
			Spacer(Modifier.weight(1f)); status(receive)
		}
		Text(when (page) {
			"pay" -> "Pay Spamcoin (BTC)"; "receive" -> "Receive XBT"; "activity" -> "Bridge activity"
			"access" -> "Bridge connection"; "detail" -> "Payment details"; else -> "Paperclip Bridge"
		}, style = MaterialTheme.typography.titleLarge, modifier = Modifier.bringIntoViewRequester(heading))
		if (s.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
		if (s.message.isNotEmpty()) Text(s.message, color = MaterialTheme.colorScheme.error)
		androidx.compose.animation.AnimatedContent(targetState = page, transitionSpec = {
			(fadeIn(tween(120)) + slideInHorizontally(tween(190)) { it / 12 * motionDirection }) togetherWith
				(fadeOut(tween(90)) + slideOutHorizontally(tween(150)) { -it / 12 * motionDirection })
		}, label = "bridge-page") { destination ->
			Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
				when (destination) {
					"home" -> {
						Text("Exchange XBT and Spamcoin (BTC) with linked Lightning invoices.")
						BoxWithConstraints {
							if (maxWidth >= 600.dp && androidx.compose.ui.platform.LocalDensity.current.fontScale <= 1.3f) {
								Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
									Column(Modifier.weight(1f)) { BridgeMenu("Pay Spamcoin (BTC)", "Use XBT from Ark or your node", !s.busy) { navigate("pay") } }
									Column(Modifier.weight(1f)) { BridgeMenu("Receive XBT", "Get paid from a Spamcoin (BTC) wallet", !s.busy) { navigate("receive") } }
								}
							} else {
								Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
									BridgeMenu("Pay Spamcoin (BTC)", "Use XBT from Ark or your node", !s.busy) { navigate("pay") }
									BridgeMenu("Receive XBT", "Get paid from a Spamcoin (BTC) wallet", !s.busy) { navigate("receive") }
								}
							}
						}
						BridgeMenu("Bridge activity", "Saved quotes and payment outcomes", !s.busy) { navigate("activity") }
						TextButton(onClick = { navigate("access") }, enabled = !s.busy) { Text("Bridge connection") }
					}
					"pay", "receive" -> {
						val incoming = destination == "receive"
						if (incoming) {
							Text("Create an invoice for your XBT node. The sender pays the matching Spamcoin (BTC) invoice.")
							OutlinedTextField(amount, { amount = it }, label = { Text("XBT amount in ${unit.title}") }, enabled = !s.busy, modifier = Modifier.fillMaxWidth())
						} else {
							OutlinedTextField(invoice, { invoice = it }, label = { Text("Spamcoin (BTC) invoice") }, minLines = 2, maxLines = 4, enabled = !s.busy, modifier = Modifier.fillMaxWidth())
							Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
								(if (canUseArk) listOf("node", "ark") else listOf("node")).forEach { value ->
									FilterChip(source == value, { source = value }, enabled = !s.busy, label = { Text(if (value == "node") "Lightning node" else "Ark balance") })
								}
							}
							if (source == "node") OutlinedTextField(fee, { fee = it }, label = { Text("Maximum routing fee in ${unit.title}") }, enabled = !s.busy, modifier = Modifier.fillMaxWidth())
						}
						Button(onClick = { onQuote(invoice, if (incoming || !canUseArk) "node" else source, incoming, unit.backendAmount(amount), unit.backendAmount(fee)) }, enabled = !s.busy, modifier = Modifier.fillMaxWidth()) {
							Text(if (incoming) "Create invoice and review" else "Review conversion")
						}
					}
					"activity" -> {
						if (s.history.isEmpty()) Text("Your bridge quotes and payments will appear here.")
						val last = ((s.history.size - 1).coerceAtLeast(0) / 10)
						val index = historyPage.coerceAtMost(last)
						s.history.drop(index * 10).take(10).forEach { record ->
							BridgeMenu(bridgeRecordTitle(record), bridgeRecordStatus(record) + " · " + record.optString("hash").take(8), !s.busy) { openRecord(record) }
						}
						if (last > 0) {
							Text("Page ${index + 1} of ${last + 1}", style = MaterialTheme.typography.bodySmall)
							Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
								OutlinedButton(onClick = { historyPage = index - 1 }, enabled = !s.busy && index > 0) { Text("Previous") }
								OutlinedButton(onClick = { historyPage = index + 1 }, enabled = !s.busy && index < last) { Text("Next") }
							}
						}
					}
					"detail" -> current?.let { record ->
						val quote = record.getJSONObject("quote")
						val incoming = record.optBoolean("receive")
						val verified = record.optBoolean("verified")
						Text(bridgeRecordTitle(record), style = MaterialTheme.typography.titleMedium)
						Text(bridgeRecordStatus(record))
						Text("Funding invoice: ${quote.getLong("pay_sat").toLocaleString()} ${if (incoming) "BTC" else "XBT"} sats")
						if (!incoming) {
							Text("Pay from ${if (record.optString("source") == "ark") "Ark balance" else "Lightning node"}")
							s.nativeQuote?.let { Text("Funding fee: ${unit.display(it.getLong("fee_sat"))} · Maximum total: ${unit.display(it.getLong("total_sat"))}") }
							s.nodeReview?.let { Text("Maximum routing fee: ${unit.display(it.feeSat)} · Maximum total: ${unit.display(quote.getLong("pay_sat") + it.feeSat)}") }
						}
						if (incoming && !verified && quote.optLong("expires_at") > now + 5) {
							Text("Share this BTC invoice with the sender.")
							NodeReceiveCode(quote.getString("hold_invoice"))
							OutlinedButton(onClick = { clipboard.setText(androidx.compose.ui.text.AnnotatedString(quote.getString("hold_invoice"))) }) { Text("Copy BTC invoice") }
						} else if (!incoming && !record.optBoolean("submitted") && !verified) {
							if (quote.optLong("expires_at") > now + 5 && (s.nativeQuote != null || s.nodeReview?.valid(now) == true)) {
								Button(onClick = onFund, enabled = !s.busy, modifier = Modifier.fillMaxWidth()) { Text("Confirm and fund bridge") }
							} else {
								Text("Review a fresh conversion before funding this saved quote.")
								OutlinedButton(onClick = { invoice = record.getString("target"); source = if (canUseArk) record.optString("source", "node") else "node"; navigate("pay") }, enabled = !s.busy) { Text("Review again") }
							}
						}
						OutlinedButton(onClick = onCheck, enabled = !s.busy) { Text("Check saved payment") }
						Text("Funding and recipient settlement are checked separately. Status checks never resend a payment.", style = MaterialTheme.typography.bodySmall)
						TextButton(onClick = { details = !details }) { Text(if (details) "Hide payment details" else "Show payment details") }
						if (details) SelectionContainer { Text("Payment hash: ${record.getString("hash")}\nRecipient invoice: ${record.getString("target")}\nFunding state: ${record.optString("funding", "not_sent")}", style = MaterialTheme.typography.bodySmall) }
					} ?: Text(if (s.busy) "Loading saved payment…" else "Choose a saved payment from Bridge activity.")
					"access" -> {
						Text("The public bridge works without a key.")
						OutlinedTextField(key, { key = it }, label = { Text("Private API key (optional)") }, visualTransformation = PasswordVisualTransformation(), enabled = !s.busy, modifier = Modifier.fillMaxWidth())
						Button(onClick = { onSaveKey(key.trim()); key = "" }, enabled = !s.busy) { Text("Save bridge access") }
					}
				}
			}
		}
	}
}

private fun Long.toLocaleString() = java.text.NumberFormat.getIntegerInstance().format(this)
private fun bridgeRecordTitle(record: org.json.JSONObject): String {
	val amount = record.optJSONObject("quote")?.optDouble("sat") ?: Double.NaN
	val text = if (amount.isFinite()) java.text.NumberFormat.getNumberInstance().apply { maximumFractionDigits = 3 }.format(amount) else "Unknown amount"
	return if (record.optBoolean("receive")) "Receive $text XBT sats" else "Pay $text BTC sats"
}
private fun bridgeRecordStatus(record: org.json.JSONObject): String = when {
	record.optBoolean("verified") -> if (record.optBoolean("receive")) "Received on your node" else "Recipient invoice paid"
	record.optString("node_state") == "ended" -> "Receiving invoice ended"
	record.optJSONObject("quote")?.optLong("expires_at")?.let { it <= System.currentTimeMillis() / 1000 + 5 } == true && !record.optBoolean("submitted") -> "Quote expired · review again"
	record.optString("bridge") in listOf("failed", "aborted", "expired") -> "Bridge ended · check funding status"
	record.optBoolean("submitted") -> "Pending · check for an update"
	else -> "Saved quote · not funded by Paperclip"
}
@Composable
private fun BridgeMenu(title: String, subtitle: String, enabled: Boolean, action: () -> Unit) {
	OutlinedButton(onClick = action, enabled = enabled, shape = RoundedCornerShape(22.dp), modifier = Modifier.fillMaxWidth()) {
		Column(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
			Text(title, style = MaterialTheme.typography.titleMedium)
			Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
		}
	}
}

@Composable
internal fun BridgeStatusBadge(model: BridgeModel, receiveXbt: Boolean? = null) {
	val observations by model.serviceHealth.collectAsStateWithLifecycle()
	val lifecycle = LocalLifecycleOwner.current.lifecycle
	var now by remember { mutableLongStateOf(android.os.SystemClock.elapsedRealtime()) }
	LaunchedEffect(model, receiveXbt, lifecycle) {
		lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
			while (isActive) {
				now = android.os.SystemClock.elapsedRealtime()
				if (receiveXbt != true) model.refreshAvailability(false)?.join()
				if (receiveXbt != false) model.refreshAvailability(true)?.join()
				now = android.os.SystemClock.elapsedRealtime()
				delay(5000)
			}
		}
	}
	fun state(direction: Boolean) = (observations[direction] ?: BridgeHealth(checking = true)).state(now)
	val state = receiveXbt?.let(::state) ?: BridgeHealthState.combined(state(false), state(true))
	BridgeStatusLabel(state)
}

@Composable
internal fun BridgeStatusLabel(state: BridgeHealthState) {
	val light = MaterialTheme.colorScheme.background.luminance() > 0.5f
	val color = when (state) {
		BridgeHealthState.LIVE -> if (light) Color(0xFF126B3B) else Color(0xFF67CF9A)
		BridgeHealthState.PAUSED, BridgeHealthState.LIMITED -> if (light) Color(0xFF944000) else MaterialTheme.colorScheme.primary
		else -> MaterialTheme.colorScheme.onSurfaceVariant
	}
	val icon = when (state) {
		BridgeHealthState.LIVE -> "✓"
		BridgeHealthState.PAUSED -> "Ⅱ"
		BridgeHealthState.LIMITED -> "◐"
		BridgeHealthState.CHECKING -> "◷"
		else -> "?"
	}
	Text("$icon ${state.title}", color = color, style = MaterialTheme.typography.labelMedium,
		modifier = Modifier.background(color.copy(alpha = 0.08f), RoundedCornerShape(50))
			.padding(horizontal = 8.dp, vertical = 5.dp)
			.semantics { contentDescription = "Bridge service: ${state.title}. Service availability, not payment status." })
}
