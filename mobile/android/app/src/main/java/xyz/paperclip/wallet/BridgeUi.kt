package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
internal fun BridgePage(model: BridgeModel, canUseArk: Boolean) {
	val unit = LocalBitcoinUnit.current
	val s by model.state.collectAsStateWithLifecycle()
	var receive by remember { mutableStateOf(false) }
	var source by remember { mutableStateOf("node") }
	var invoice by remember { mutableStateOf("") }
	var amount by remember { mutableStateOf("") }
	var fee by remember { mutableStateOf(unit.input(100)) }
	var key by remember { mutableStateOf("") }
	LaunchedEffect(Unit) { model.load() }
	if (s.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
	if (s.message.isNotEmpty()) Text(s.message, color = MaterialTheme.colorScheme.error)
	Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
		Text("Paperclip Bridge", style = MaterialTheme.typography.headlineSmall)
		Text(
			"Exchange XBT and Spamcoin (BTC) using linked Lightning invoices. Review the quote and funding fee before confirming.",
		)
		Row {
			Text("Receive XBT on your node", Modifier.weight(1f))
			Switch(receive, { receive = it })
		}
		if (receive)
			OutlinedTextField(
				amount,
				{ amount = it },
				label = { Text("XBT amount in ${unit.title}") },
				modifier = Modifier.fillMaxWidth(),
			)
		else {
			OutlinedTextField(
				invoice,
				{ invoice = it },
				label = { Text("Spamcoin (BTC) mainnet invoice") },
				minLines = 3,
				modifier = Modifier.fillMaxWidth(),
			)
			Row {
				(if (canUseArk) listOf("node", "ark") else listOf("node")).forEach { v ->
					FilterChip(source == v, { source = v }, label = { Text("Pay from $v") })
				}
			}
			if (source == "node")
				OutlinedTextField(
					fee,
					{ fee = it },
					label = { Text("Maximum routing fee in ${unit.title}") },
					modifier = Modifier.fillMaxWidth(),
				)
		}
		Button(
			onClick = {
				model.quote(
					invoice,
					source,
					receive,
					unit.backendAmount(amount),
					unit.backendAmount(fee),
				)
			},
			enabled = !s.busy,
		) {
			Text("Request quote")
		}
		s.record?.let { r ->
			val q = r.getJSONObject("quote")
			HorizontalDivider()
			Text(
				if (r.optBoolean("receive")) "Receive XBT" else "Pay Spamcoin (BTC)",
				style = MaterialTheme.typography.titleLarge,
			)
			Text("Receiving network invoice: ${q.getDouble("sat")} sats")
			Text(
				"Funding invoice: ${q.getLong("pay_sat")} sats · ${if(r.optBoolean("receive"))"BTC" else "XBT"}",
			)
			s.nativeQuote?.let {
				Text(
					"Ark funding fee: ${unit.display(it.getLong("fee_sat"))} · Total XBT debit: ${unit.display(it.getLong("total_sat"))}",
				)
			}
			s.nodeReview?.let { Text("Maximum XBT routing fee: ${unit.display(it.feeSat)}") }
			if (r.optBoolean("receive") && !r.optBoolean("verified")) {
				Text("Pay this BTC invoice from your BTC wallet. This app will not pay it for you.")
				NodeReceiveCode(q.getString("hold_invoice"))
				SelectionContainer {
					Text(q.getString("hold_invoice"), style = MaterialTheme.typography.bodySmall)
				}
			} else if (!r.optBoolean("submitted"))
				Button(
					onClick = model::fund,
					enabled = !s.busy && (s.nativeQuote != null || s.nodeReview != null),
				) {
					Text("Confirm and fund bridge")
				}
			Text(
				if (r.optBoolean("verified")) "Receiving invoice paid"
				else "Bridge status: ${r.optString("bridge","quoted")}",
			)
			if (!r.optBoolean("receive"))
				Text("Funding status: ${r.optString("funding","not_sent")}")
			Text(
				"Funding the bridge and settling the recipient's invoice are separate steps. Uncertain payments stay recorded and are never automatically resent.",
				style = MaterialTheme.typography.bodySmall,
			)
			OutlinedButton(onClick = model::check, enabled = !s.busy) {
				Text("Check saved payment")
			}
		}
		HorizontalDivider()
		OutlinedTextField(
			key,
			{ key = it },
			label = { Text("Private bridge API key (optional)") },
			visualTransformation = PasswordVisualTransformation(),
			modifier = Modifier.fillMaxWidth(),
		)
		TextButton(
			onClick = {
				model.saveKey(key.trim())
				key = ""
			},
			enabled = !s.busy,
		) {
			Text("Save bridge access")
		}
	}
}
