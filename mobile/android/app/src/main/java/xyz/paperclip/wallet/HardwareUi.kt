package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.util.Base64
import kotlinx.coroutines.delay
import org.json.JSONObject

@Composable
internal fun HardwarePayment(s: WalletState, model: WalletModel, boarding: Boolean = false) {
	val unit = LocalBitcoinUnit.current
	var sourceID by remember(s.activeID) { mutableStateOf("") }
	val importOperation = if (boarding) "ark_hardware_import" else "hardware_import"
	var destination by remember(s.activeID) { mutableStateOf("") }
	var amount by remember(s.activeID) { mutableStateOf("") }
	var maximum by remember { mutableStateOf(false) }
	var scanning by remember { mutableStateOf(false) }
	var collector by remember(s.activeID) { mutableStateOf(SigningQrCollector()) }
	var prepared by remember(s.activeID) { mutableStateOf<JSONObject?>(null) }
	var verified by remember(s.activeID) { mutableStateOf("") }
	var showQr by remember { mutableStateOf(false) }
	var error by remember { mutableStateOf("") }
	var signed by remember { mutableStateOf("") }
	LaunchedEffect(s.toolsResult) {
		s.toolsResult?.let {
			if (it.has("psbt")) {
				prepared = it
				verified = ""
			} else if (it.optBoolean("verified")) verified = it.getString("txid")
		}
	}
	Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
		Text(
			if (boarding) "Hardware wallet to Ark" else "Hardware payment",
			style = MaterialTheme.typography.titleLarge,
		)
		Text(
			"Review the recipient, amount, fee and change on your hardware wallet. Every signature must use unified SIGHASH_ALL (0x21).",
		)
		if (prepared == null) {
			if (boarding) {
				Text(
					"Ark funds will use this mobile wallet’s keys and recovery backup after boarding. Keep a current encrypted backup and on-chain recovery funds.",
				)
				s.profiles
					.filter { it.kind == "hardware" && it.network == s.network }
					.forEach { profile ->
						FilterChip(
							sourceID == profile.id,
							{ sourceID = profile.id },
							label = { Text(profile.name) },
						)
					}
			} else
				OutlinedTextField(
					destination,
					{ destination = it },
					label = { Text("XBT address") },
					modifier = Modifier.fillMaxWidth(),
				)
			OutlinedTextField(
				amount,
				{ amount = it },
				label = { Text("Amount in ${unit.title}") },
				enabled = !maximum,
				modifier = Modifier.fillMaxWidth(),
			)
			if (!boarding)
				Row {
					Text("Send Max", Modifier.weight(1f))
					Switch(maximum, { maximum = it })
				}
			if (boarding)
				Button(
					onClick = { model.prepareHardwareBoard(sourceID, unit.backendAmount(amount)) },
					enabled = s.connected && !s.busy && sourceID.isNotEmpty(),
				) {
					Text("Review boarding")
				}
			else
				Button(
					onClick = {
						val f =
							JSONObject()
								.put("destination", destination.trim())
								.put("send_max", maximum)
						if (!maximum) unit.parse(amount)?.let { f.put("amount_sat", it) }
						model.tool("hardware_prepare", f)
					},
					enabled = s.connected && !s.busy,
				) {
					Text("Review payment")
				}
		} else {
			val p = prepared!!
			SelectionContainer { Text(if (boarding) p.getString("address") else destination) }
			Text("Recipient receives: ${unit.display(p.getLong("amount_sat"))}")
			Text(
				"Network fee: ${unit.display(p.getLong(if(boarding)"network_fee_sat" else "fee_sat"))} · Total: ${unit.display(p.getLong("total_sat"))}",
			)
			if (boarding)
				Text(
					"Recovery funding deducted: ${unit.display(p.getLong("reserve_sat"))} · Spendable in Ark: ${unit.display(p.getLong("net_sat"))}",
				)
			if (verified.isEmpty()) {
				Button(onClick = { showQr = !showQr }) {
					Text(if (showQr) "Hide signing QR" else "Show signing QR")
				}
				if (showQr) {
					val frames =
						remember(p) {
							SigningQr.frames(Base64.getDecoder().decode(p.getString("psbt")))
						}
					var index by remember(frames) { mutableStateOf(0) }
					LaunchedEffect(frames) {
						while (true) {
							delay(250)
							index = (index + 1) % frames.size
						}
					}
					NodeReceiveCode(frames[index])
					Text("Frame ${index+1} of ${frames.size}")
				}
				Button(
					onClick = {
						collector = SigningQrCollector()
						scanning = true
					},
					enabled = !s.busy,
				) {
					Text("Scan signed QR")
				}
				OutlinedTextField(
					signed,
					{ signed = it },
					label = { Text("Or paste signed PSBT/transaction") },
					modifier = Modifier.fillMaxWidth(),
				)
				TextButton(
					onClick = {
						runCatching { SigningQr.binary(signed) }
							.fold(
								onSuccess = { bytes ->
									model.tool(
										importOperation,
										JSONObject()
											.put(
												"signed",
												Base64.getEncoder().encodeToString(bytes),
											),
									)
								},
								onFailure = { error = "Invalid signed PSBT or transaction" },
							)
					},
					enabled = !s.busy && signed.isNotBlank(),
				) {
					Text("Verify pasted signature")
				}
			} else {
				Text("Signatures verified. Transaction matches the reviewed request.")
				SelectionContainer { Text(verified) }
				Button(
					onClick = {
						model.tool(
							if (boarding) "ark_hardware_commit" else "hardware_broadcast",
							JSONObject().put("txid", verified),
						)
						prepared = null
						verified = ""
						signed = ""
					},
					enabled = !s.busy,
				) {
					Text(if (boarding) "Confirm and board" else "Confirm and broadcast")
				}
			}
			TextButton(
				onClick = {
					model.tool(
						if (boarding) "ark_hardware_cancel" else "hardware_cancel",
						JSONObject().put("request_id", p.optString("request_id")),
					)
					prepared = null
					verified = ""
					signed = ""
					showQr = false
				},
				enabled = !s.busy,
			) {
				Text("Start over")
			}
		}
		if (error.isNotEmpty()) Text(error, color = MaterialTheme.colorScheme.error)
		s.result?.let { Text(PaymentStatus.from(it.optString("state")).title) }
	}
	if (scanning)
		QrScanner(onClose = { scanning = false }) { frame ->
			val data = collector.accept(frame)
			if (data == null) false
			else {
				model.tool(
					importOperation,
					JSONObject().put("signed", Base64.getEncoder().encodeToString(data)),
				)
				true
			}
		}
}
