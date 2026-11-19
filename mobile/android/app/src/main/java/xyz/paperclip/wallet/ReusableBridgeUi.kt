package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.tween
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import org.json.JSONObject

@Composable
internal fun ReusableBridgePage(initialDestination: String = "", canUseArk: Boolean = false, onPayOffer: (String, Boolean) -> Unit = { _, _ -> }, onBack: () -> Unit) {
	val model: ReusableBridgeModel = androidx.lifecycle.viewmodel.compose.viewModel()
	val state by model.state.collectAsStateWithLifecycle()
	val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
	LaunchedEffect(model, lifecycle) {
		lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
			model.load(); while (true) { kotlinx.coroutines.delay(30000); model.refreshAvailability() }
		}
	}
	ReusableBridgeContent(state, initialDestination, canUseArk, onPayOffer, onBack, model::create, model::restore, model::action, model::useNode)
}

@Composable
internal fun ReusableBridgeContent(state: ReusableBridgeState, initialDestination: String = "", canUseArk: Boolean = false,
	onPayOffer: (String, Boolean) -> Unit, onBack: () -> Unit, onCreate: (String, Boolean) -> Unit,
	onRestore: (String) -> Unit, onAction: (JSONObject, String) -> Unit, onNode: () -> Unit) {
	var destination by remember { mutableStateOf(initialDestination) }; var xbt by remember { mutableStateOf(initialDestination.isEmpty()) }
	var review by remember { mutableStateOf(false) }; var key by remember { mutableStateOf("") }
	var selected by remember { mutableStateOf<String?>(null) }; var revoke by remember { mutableStateOf<JSONObject?>(null) }
	var receivingDetails by remember { mutableStateOf(false) }
	var scanning by remember { mutableStateOf(false) }
	if (scanning) QrScanner(onClose = { scanning = false }) { frame ->
		destination = PaymentInput.scan(frame).destination; review = false; true
	}
	var recovery by remember { mutableStateOf(false) }; var error by remember { mutableStateOf("") }
	val context = androidx.compose.ui.platform.LocalContext.current
	LaunchedEffect(state.nodeOffer) { if (state.nodeOffer.isNotEmpty()) { destination = state.nodeOffer; xbt = true; review = false } }
	androidx.activity.compose.BackHandler { if (!state.busy) { if (selected != null) selected = null else if (review) review = false else onBack() } }
	Column(Modifier.animateContentSize(tween(180)), verticalArrangement = Arrangement.spacedBy(12.dp)) {
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
			TextButton(onClick = onBack, enabled = !state.busy) { Text("Back to bridge") }
			BridgeStatusLabel(if (state.available == true) BridgeHealthState.LIVE else if (state.available == false) BridgeHealthState.PAUSED else BridgeHealthState.UNKNOWN)
		}
		Text("Reusable bridge offers", style = MaterialTheme.typography.titleLarge)
		if (!review && selected == null) Text("Receive across networks with one BOLT12 offer. Each payment uses the current exchange rate, fees and bridge limits.")
		if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
		if (state.message.isNotEmpty()) Text(state.message)
		if (error.isNotEmpty()) Text(error, color = MaterialTheme.colorScheme.error)
		val row = state.rows.firstOrNull { it.getString("id") == selected }
		if (row != null) {
			CardBlock("Saved offer") {
				val binding = row.optJSONObject("binding")
				if (binding != null) {
					Text(if (binding.getString("direction") == "toBLAKE2b") "Sender pays BTC · Recipient receives XBT" else "Sender pays XBT · Recipient receives BTC", style = MaterialTheme.typography.titleMedium)
					if (!binding.getBoolean("revoked") && !row.optBoolean("revocation_requested")) {
						NodeReceiveCode(binding.getString("offer"))
						if (binding.getString("direction") == "toSHA256") {
							WalletPrimaryButton(onClick = { onPayOffer(binding.getString("offer"), false) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) { Text("Pay from my Lightning node") }
							if (canUseArk) OutlinedButton(onClick = { onPayOffer(binding.getString("offer"), true) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) { Text("Pay from Ark") }
						}
						Text(if (binding.getString("direction") == "toBLAKE2b") "Share with a BTC wallet that supports BOLT12." else "Pay this XBT offer from Ark or your Lightning node using the normal send screen. Review the requested XBT amount there.")
					} else Text(if (binding.getBoolean("revoked")) "Revoked" else "Revocation not confirmed · sharing disabled")
				} else Text("Registration not confirmed. Check status or retry this same saved request.")
				OutlinedButton(onClick = { onAction(row, "lookup") }, enabled = !state.busy) { Text("Check status") }
				if (binding == null && row.has("destination") && !row.optBoolean("revocation_requested")) OutlinedButton(onClick = { onAction(row, "register") }, enabled = !state.busy) { Text("Retry saved registration") }
				TextButton(onClick = { recovery = !recovery }) { Text("Private recovery key") }
				if (recovery) {
					Text("Keep this key private. It can restore or revoke the offer, but cannot spend funds or change its destination. Save it separately before removing the app.", style = MaterialTheme.typography.bodySmall)
					TextButton(onClick = {
						val clip = android.content.ClipData.newPlainText("Private management key", row.getString("token"))
						if (android.os.Build.VERSION.SDK_INT >= 33) clip.description.extras = android.os.PersistableBundle().apply { putBoolean(android.content.ClipDescription.EXTRA_IS_SENSITIVE, true) }
						(context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(clip)
					}) { Text("Copy private management key") }
				}
				if (binding?.optBoolean("revoked") != true) TextButton(onClick = { revoke = row }, enabled = !state.busy) { Text("Revoke offer", color = MaterialTheme.colorScheme.error) }
				TextButton(onClick = { selected = null; recovery = false }) { Text("Back to offers") }
			}
		} else {
			CardBlock(if (review) "Review receiving wallet" else "Create an offer") {
				if (review) {
					Text(if (xbt) "Sender pays BTC · Recipient receives XBT" else "Sender pays XBT · Recipient receives BTC", style = MaterialTheme.typography.titleMedium)
					TextButton(onClick = { receivingDetails = !receivingDetails }) { Text(if (receivingDetails) "Hide receiving offer" else "Receiving offer") }
					if (receivingDetails) androidx.compose.foundation.text.selection.SelectionContainer { Text(destination, style = MaterialTheme.typography.bodySmall) }
					Text("The receiving wallet must stay reachable. This registers a reusable route; it does not send funds. Revoking stops new payments while in-flight payments finish or refund.")
					WalletPrimaryButton(onClick = { onCreate(destination, xbt); review = false }, enabled = !state.busy && state.loaded, modifier = Modifier.fillMaxWidth()) { Text("Create reusable offer") }
					TextButton(onClick = { review = false }, enabled = !state.busy) { Text("Edit") }
				} else {
					SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
						listOf(true, false).forEachIndexed { index, value -> SegmentedButton(selected = xbt == value, onClick = { xbt = value }, enabled = !state.busy, shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(if (value) "Receive XBT" else "Receive BTC") } }
					}
					OutlinedTextField(destination, { destination = it }, label = { Text("Receiving wallet’s amountless BOLT12 offer") }, modifier = Modifier.fillMaxWidth(), enabled = !state.busy, minLines = 2, maxLines = 4)
					TextButton(onClick = { scanning = true }, enabled = !state.busy) { Text("Scan receiving offer") }
					if (xbt) TextButton(onClick = onNode, enabled = !state.busy) { Text("Use my connected Lightning node") }
					Text("Use a Lightning wallet’s amountless offer. Receiving into Ark through the bridge is not supported.", style = MaterialTheme.typography.bodySmall)
					WalletPrimaryButton(onClick = { try { ReusableOffer.validate(destination.trim(), xbt); destination = destination.trim(); review = true; error = "" } catch (_: Exception) { error = "Use an unexpired, amountless mainnet BOLT12 offer for the receiving currency." } }, enabled = !state.busy && state.loaded && state.available == true, modifier = Modifier.fillMaxWidth()) { Text("Review offer") }
				}
			}
			if (!review) CardBlock("Your saved offers") {
				state.rows.reversed().forEach { saved ->
					val binding = saved.optJSONObject("binding")
					BridgeMenu(if (binding == null && !saved.has("xbt")) "Restore pending" else if (binding?.optString("direction") == "toBLAKE2b" || saved.optBoolean("xbt")) "Receive XBT" else "Receive BTC", if (binding?.optBoolean("revoked") == true) "Revoked" else if (binding == null) "Needs status check" else "Reusable offer", !state.busy) { selected = saved.getString("id"); recovery = false }
				}
				TextButton(onClick = { recovery = !recovery }) { Text("Restore with a management key") }
				if (recovery) {
					OutlinedTextField(key, { key = it }, label = { Text("Private management key") }, visualTransformation = PasswordVisualTransformation(), enabled = !state.busy, modifier = Modifier.fillMaxWidth())
					WalletPrimaryButton(onClick = { onRestore(key); key = "" }, enabled = !state.busy && state.loaded) { Text("Restore offer") }
				}
			}
		}
	}
	revoke?.let { row -> AlertDialog(onDismissRequest = { revoke = null }, title = { Text("Stop new payments?") }, text = { Text("In-flight payments can still finish or refund. The receiving wallet’s original offer stays unchanged.") }, confirmButton = { TextButton(onClick = { onAction(row, "revoke"); revoke = null }) { Text("Revoke offer") } }, dismissButton = { TextButton(onClick = { revoke = null }) { Text("Cancel") } }) }
}
