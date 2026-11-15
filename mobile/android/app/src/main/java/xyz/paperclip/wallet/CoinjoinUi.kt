package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.json.JSONArray
import org.json.JSONObject

private fun JSONObject.rows(key: String): List<JSONObject> =
	optJSONArray(key)?.let { a ->
		(0 until a.length()).map { a.getJSONObject(it) }
	} ?: emptyList()

@Composable
internal fun CoinjoinPage(model: CoinjoinModel, walletID: String, mainnet: Boolean) {
	val unit = LocalBitcoinUnit.current
	val state by model.state.collectAsStateWithLifecycle()
	var relay by remember { mutableStateOf("wss://relay.kilombino.com") }
	var tor by remember { mutableStateOf(true) }
	var transfer by remember { mutableStateOf<JSONObject?>(null) }
	var confirmation by remember { mutableStateOf<Pair<String, JSONObject>?>(null) }
	LaunchedEffect(walletID, mainnet) { if (mainnet) model.load(walletID) }
	DisposableEffect(model) { onDispose { model.stop() } }
	if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
	if (state.message.isNotBlank()) Text(state.message)
	Text("Previous CoinJoin", style = MaterialTheme.typography.headlineSmall)
	if (!mainnet) {
		Text("Previous Kilojoin accounts use an XBT mainnet mobile wallet.")
		return
	}
	Text(
		"Manage existing Kilojoin funds and finish or recover previous rounds. New CoinJoin activity uses JoinBlaket. Your coins have not been moved into its jars.",
	)
	transfer?.let { coin ->
		CoinjoinTransfer(coin, state, model) {
			transfer = null
			model.clearQuote()
		}
		return
	}
	OutlinedTextField(
		relay,
		{ relay = it },
		label = { Text("Secure relay URL") },
		modifier = Modifier.fillMaxWidth(),
		enabled = !state.connected && !state.busy,
	)
	Row {
		Text("Use Tor", Modifier.weight(1f))
		Switch(tor, { tor = it }, enabled = !state.connected && !state.busy)
	}
	Button(
		onClick = { model.connect(relay.trim(), tor) },
		enabled = !state.busy && !state.connected,
	) {
		Text("Connect to relay")
	}
	Text(
		"Keep this page open while participating. Returning here reconnects to the saved round’s original relay and route.",
	)
	Card(Modifier.fillMaxWidth()) {
		Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
			Text("Separate Coinjoin account", style = MaterialTheme.typography.titleMedium)
			Text("${unit.display(state.snapshot.optLong("balance_sat"))}")
			Button(onClick = { model.action("coinjoin_sync") }, enabled = !state.busy) {
				Text("Refresh account")
			}
			OutlinedButton(
				onClick = {
					confirmation =
						"Scan account from seed" to JSONObject().put("op", "coinjoin_recover")
				},
				enabled = !state.busy,
			) {
				Text("Recover account")
			}
			if (state.snapshot.optBoolean("legacy_account"))
				OutlinedButton(
					onClick = {
						confirmation =
							"Move Coinjoin to its separate account" to
								JSONObject().put("op", "coinjoin_migrate")
					},
					enabled = !state.busy,
				) {
					Text("Migrate legacy account")
				}
		}
	}
	for (round in state.snapshot.rows("rounds")) {
		Card(Modifier.fillMaxWidth()) {
			Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
				Text("Round ${round.getString("id")}", style = MaterialTheme.typography.titleMedium)
				Text("${round.optString("phase")} · ${round.optInt("peers")} participants")
				if (round.optString("reason").isNotEmpty()) Text(round.getString("reason"))
				for ((label, key) in
					listOf(
						"Selected inputs" to "input",
						"Mixed total" to "amount_sat",
						"Change" to "change_sat",
						"Your miner fee" to "fee_sat",
					)) Text("$label: ${unit.display(round.optLong(key))}")
				val id = round.getString("id")
				fun request(title: String, op: String, fields: JSONObject = JSONObject()) {
					confirmation = title to fields.put("op", op).put("id", id)
				}
				if (round.optBoolean("active")) {
					if (round.optBoolean("creator") && round.optString("phase") == "open")
						Button(
							onClick = { request("Start participant vote", "coinjoin_close") },
							enabled = !state.busy && state.connected,
						) {
							Text("Start participant vote")
						}
					if (round.optString("phase") == "voting" && !round.optBoolean("voted")) {
						Button(
							onClick = {
								request(
									"Accept round",
									"coinjoin_vote",
									JSONObject().put("accept", true),
								)
							},
							enabled = !state.busy && state.connected,
						) {
							Text("Accept round")
						}
						OutlinedButton(
							onClick = {
								request(
									"Decline round",
									"coinjoin_vote",
									JSONObject().put("accept", false),
								)
							},
							enabled = !state.busy && state.connected,
						) {
							Text("Decline")
						}
					}
					val plan =
						round.optString("plan_id").takeUnless { it.isBlank() || it == "null" }
					if (
						plan != null &&
							round.optString("phase") == "signing" &&
							!round.optBoolean("signed")
					) {
						SelectionContainer { Text("Transaction: $plan") }
						Text(
							"Whole transaction fee: ${unit.display(round.optLong("total_fee_sat"))}. Mixed outputs: ${round.optInt("outputs")}",
						)
						Text(
							"The backend verifies all inputs, outputs and fees. Once shared, your signature cannot be recalled.",
						)
						Button(
							onClick = {
								request(
									"Approve and share signature",
									"coinjoin_sign",
									JSONObject().put("plan_id", plan),
								)
							},
							enabled = !state.busy && state.connected,
						) {
							Text("Approve and share signature")
						}
					}
					if (round.optBoolean("can_broadcast"))
						Button(
							onClick = {
								request("Broadcast signed Coinjoin", "coinjoin_broadcast")
							},
							enabled = !state.busy,
						) {
							Text("Broadcast transaction")
						}
					if (!round.optBoolean("signed"))
						OutlinedButton(
							onClick = { request("Leave this round", "coinjoin_leave") },
							enabled = !state.busy,
						) {
							Text("Leave round")
						}
					else
						Text(
							"Signature released. Inputs remain reserved until this transaction or a conflicting spend is confirmed.",
						)
				}
			}
		}
	}
	Text("Coins", style = MaterialTheme.typography.titleMedium)
	for (coin in state.snapshot.rows("coins")) {
		OutlinedButton(
			onClick = {
				transfer = coin
				model.clearQuote()
			},
			enabled = !state.busy && coin.optBoolean("available"),
			modifier = Modifier.fillMaxWidth(),
		) {
			Text(
				"${unit.display(coin.getLong("amount_sat"))} · ${coin.optString("label")} · ${coin.getString("outpoint").take(12)}…",
			)
		}
	}
	Text("Account activity", style = MaterialTheme.typography.titleMedium)
	for (row in state.snapshot.rows("activity")) SelectionContainer {
		Text(
			"${unit.display(row.optLong("change_sat"))} · ${if(row.optBoolean("confirmed"))"Confirmed" else "Pending"}\n${row.optString("txid")}",
		)
	}
	confirmation?.let { (title, fields) ->
		AlertDialog(
			onDismissRequest = { confirmation = null },
			title = { Text(title) },
			text = {
				Text(
					if (fields.optString("op") == "coinjoin_sign")
						"This releases your signature to the participants and cannot be undone."
					else "Confirm this action for the selected Coinjoin account and round.",
				)
			},
			confirmButton = {
				TextButton(
					onClick = {
						val op = fields.getString("op")
						fields.remove("op")
						model.action(op, fields)
						confirmation = null
					},
				) {
					Text("Confirm")
				}
			},
			dismissButton = { TextButton(onClick = { confirmation = null }) { Text("Cancel") } },
		)
	}
}

@Composable
private fun CoinjoinTransfer(
	coin: JSONObject,
	state: CoinjoinState,
	model: CoinjoinModel,
	done: () -> Unit,
) {
	val unit = LocalBitcoinUnit.current
	var action by remember { mutableStateOf("withdraw") }
	var destination by remember { mutableStateOf("") }
	var amount by remember { mutableStateOf("") }
	var rate by remember { mutableStateOf("2") }
	var unmixed by remember { mutableStateOf(false) }
	var confirm by remember { mutableStateOf(false) }
	Text("Transfer one coin: ${unit.display(coin.getLong("amount_sat"))}")
	Row {
		listOf("withdraw", if (coin.optString("label") == "mixed") "board" else "exact").forEach {
			mode ->
			FilterChip(
				selected = action == mode,
				onClick = {
					action = mode
					model.clearQuote()
				},
				label = { Text(mode) },
			)
		}
	}
	if (action == "withdraw")
		OutlinedTextField(
			destination,
			{
				destination = it
				model.clearQuote()
			},
			label = { Text("XBT destination address") },
		)
	if (action == "exact") {
		OutlinedTextField(
			amount,
			{
				amount = it
				model.clearQuote()
			},
			label = { Text("Pool denomination in ${unit.title}") },
		)
		OutlinedTextField(
			rate,
			{
				rate = it
				model.clearQuote()
			},
			label = { Text("Pool fee rate (sat/vB)") },
		)
		Row {
			Text("This source coin is unmixed")
			Switch(
				unmixed,
				{
					unmixed = it
					model.clearQuote()
				},
			)
		}
		Text(
			"The prepared coin includes the no-change pool fee share. This preparation transaction has a separate network fee.",
		)
	}
	if (action == "board")
		Text(
			"Only this mixed coin is boarded. Ark recovery funding is deducted after the network fee.",
		)
	val exact = runCatching {
		val denomination = checkNotNull(unit.parse(amount))
		val feeRate = rate.toDouble()
		require(
			denomination in 10000..100000000 &&
				feeRate.isFinite() &&
				feeRate in 1.0..500.0 &&
				unmixed,
		)
		denomination + kotlin.math.ceil(feeRate * 104.25).toLong()
	}
		.getOrNull()
	Button(
		onClick = {
			model.action(
				"coinjoin_quote",
				JSONObject()
					.put("outpoint", coin.getString("outpoint"))
					.put("action", action)
					.put("destination", destination.trim())
					.put("amount_sat", exact ?: 0)
					.put("unmixed_confirmed", unmixed),
			)
		},
		enabled = !state.busy && (action != "exact" || exact != null),
	) {
		Text("Review transfer")
	}
	state.quote?.let { q ->
		SelectionContainer {
			Text(
				"Destination: ${q.getString("destination")}\nInput: ${unit.display(q.getLong("input_sat"))}\nAmount: ${unit.display(q.getLong("amount_sat"))}\nNetwork fee: ${unit.display(q.getLong("fee_sat"))}\nRecovery funding: ${unit.display(q.getLong("reserve_sat"))}\nNet: ${unit.display(q.getLong("net_sat"))}\nChange: ${unit.display(q.getLong("change_sat"))}",
			)
		}
		Button(onClick = { confirm = true }, enabled = !state.busy) { Text("Confirm transfer") }
		if (confirm)
			AlertDialog(
				onDismissRequest = { confirm = false },
				title = { Text("Broadcast this transfer?") },
				text = { Text("The reviewed transaction will be signed and broadcast.") },
				confirmButton = {
					TextButton(
						onClick = {
							model.action(
								"coinjoin_transfer",
								JSONObject().put("quote_id", q.getString("quote_id")),
							)
							confirm = false
							done()
						},
					) {
						Text("Broadcast")
					}
				},
				dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } },
			)
	}
	TextButton(onClick = done, enabled = !state.busy) { Text("Back") }
}
