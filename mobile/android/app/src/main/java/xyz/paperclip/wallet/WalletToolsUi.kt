package xyz.paperclip.wallet

import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import org.json.JSONObject

@Composable
internal fun WalletPicker(s: WalletState, model: WalletModel) {
	var name by remember { mutableStateOf("") }
	var phrase by remember { mutableStateOf("") }
	var key by remember { mutableStateOf("") }
	var origin by remember { mutableStateOf("") }
	var mode by remember { mutableStateOf("hot") }
	var script by remember { mutableStateOf("segwit") }
	var entropyOptions by remember { mutableStateOf(false) }
	if (entropyOptions) SeedGenerationDialog(model) { entropyOptions = false }
	var generating by remember { mutableStateOf(false) }
	var verifying by remember { mutableStateOf(false) }
	var confirmation by remember { mutableStateOf("") }
	var removal by remember { mutableStateOf<WalletProfile?>(null) }
	var backupAcknowledged by remember { mutableStateOf(false) }
	var scanning by remember { mutableStateOf(false) }
	var collector by remember { mutableStateOf(SigningQrCollector()) }
	val context = LocalContext.current
	val activity = LocalActivity.current as? MainActivity
	DisposableEffect(model) { onDispose { model.clearPhrase() } }
	Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
		s.profiles.forEach { p ->
			OutlinedButton(
				onClick = { model.selectWallet(p.id) },
				enabled = !s.busy && p.id != s.activeID,
				modifier = Modifier.fillMaxWidth(),
			) {
				Text("${p.name} · ${p.kind}${if(p.id==s.activeID)" · selected" else ""}")
			}
			if (p.kind != "hot")
				TextButton(onClick = { model.exportPublic(p.id) }, enabled = !s.busy) {
					Text("Export ${p.name} public descriptor")
				}
			TextButton(
				onClick = {
					removal = p
					confirmation = ""
					backupAcknowledged = false
				},
				enabled = !s.busy,
			) {
				Text("Remove ${p.name} from device")
			}
		}
		s.toolsResult
			?.takeIf { it.has("descriptor") }
			?.let { export ->
				val text = export.toString(2)
				SelectionContainer { Text(text) }
				NodeReceiveCode(export.getString("descriptor"))
				TextButton(
					onClick = {
						context.startActivity(
							android.content.Intent.createChooser(
								android.content
									.Intent(android.content.Intent.ACTION_SEND)
									.setType("text/plain")
									.putExtra(android.content.Intent.EXTRA_TEXT, text),
								"Share public wallet",
							),
						)
					},
				) {
					Text("Share public export")
				}
			}
		Text("Add or rename a wallet", style = MaterialTheme.typography.titleLarge)
		OutlinedTextField(
			name,
			{ name = it },
			label = { Text("Wallet name") },
			modifier = Modifier.fillMaxWidth(),
		)
		TextButton(
			onClick = { model.renameWallet(s.activeID, name) },
			enabled = name.isNotBlank() && !s.busy,
		) {
			Text("Rename selected wallet")
		}
		Row {
			listOf("hot", "hardware", "watch").forEach { kind ->
				FilterChip(
					mode == kind,
					{
						mode = kind
						model.clearTools()
					},
					label = { Text(kind) },
				)
			}
		}
		if (mode == "hot") {
			if (generating) {
				if (s.phrase.isNotEmpty()) {
					if (!verifying) {
						Text(
							"Write down these recovery words offline. Anyone with them can access your wallet.",
						)
						SeedWords(s.phrase.split(" "))
						Button(
							onClick = {
								verifying = true
								confirmation = ""
							},
						) {
							Text("I wrote down every word")
						}
					} else {
						OutlinedTextField(
							confirmation,
							{ confirmation = it },
							label = { Text("Enter every recovery word in order") },
							minLines = 3,
						)
						val matches =
							confirmation.trim().lowercase().split(Regex("\\s+")) ==
								s.phrase.split(" ")
						Button(
							onClick = {
								model.addWallet(s.phrase, name)
								confirmation = ""
								generating = false
								verifying = false
							},
							enabled = matches && name.isNotBlank() && !s.busy,
						) {
							Text("Verify and create wallet")
						}
					}
				} else if (!s.busy) {
					TextButton(onClick = { entropyOptions = true }) {
						Text("Choose recovery word generation")
					}
				}
				TextButton(
					onClick = {
						generating = false
						verifying = false
						confirmation = ""
						model.clearPhrase()
					},
					enabled = !s.busy,
				) {
					Text("Cancel wallet creation")
				}
			} else
				Button(
					onClick = {
						generating = true
						entropyOptions = true
					},
					enabled = name.isNotBlank() && !s.busy,
				) {
					Text("Create new mobile wallet")
				}
			OutlinedTextField(
				phrase,
				{ phrase = it },
				label = { Text("12 or 24 recovery words") },
				minLines = 3,
				modifier = Modifier.fillMaxWidth(),
			)
			Text(
				"Use a full encrypted backup to restore existing Ark funds. Seed words alone do not restore complete Ark recovery data.",
				style = MaterialTheme.typography.bodySmall,
			)
			Button(
				onClick = {
					model.addWallet(phrase, name)
					phrase = ""
				},
				enabled = name.isNotBlank() && phrase.isNotBlank() && !s.busy,
			) {
				Text("Import mobile wallet")
			}
		} else {
			OutlinedTextField(
				key,
				{
					key = it
					model.clearTools()
				},
				label = { Text("Public descriptor or extended public key") },
				minLines = 3,
				modifier = Modifier.fillMaxWidth(),
			)
			OutlinedTextField(
				origin,
				{
					origin = it
					model.clearTools()
				},
				label = { Text("Key origin fingerprint/path") },
				modifier = Modifier.fillMaxWidth(),
			)
			Row {
				listOf("segwit", "taproot", "nested", "legacy").forEach { kind ->
					FilterChip(
						script == kind,
						{
							script = kind
							model.clearTools()
						},
						label = { Text(kind) },
					)
				}
			}
			Text(
				"Import public information only. Hardware private keys stay on the signing device.",
			)
			Button(
				onClick = {
					collector = SigningQrCollector()
					scanning = true
				},
				enabled = !s.busy,
			) {
				Text("Scan public wallet QR")
			}
			Button(
				onClick = { model.previewPublic(key, origin, script, mode == "hardware") },
				enabled = key.isNotBlank() && !s.busy,
			) {
				Text("Review public descriptor")
			}
			s.toolsResult
				?.takeIf { it.has("receive") && it.has("change") }
				?.let { review ->
					Text(
						"Network: ${s.network}. Review the account and key origin before importing.",
					)
					SelectionContainer {
						Text(
							"Receive: ${review.getString("receive")}\nChange: ${review.getString("change")}",
						)
					}
					Button(
						onClick = {
							model.importPublic(key, origin, script, mode == "hardware", name)
						},
						enabled = name.isNotBlank() && !s.busy,
					) {
						Text("Confirm public wallet import")
					}
				}
		}
	}
	if (scanning)
		QrScanner(onClose = { scanning = false }) { frame ->
			val data = collector.accept(frame, publicWallet = true)
			if (data == null) false
			else {
				require(data.size <= 4096)
				val text =
					Charsets.UTF_8.newDecoder()
						.onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
						.decode(java.nio.ByteBuffer.wrap(data))
						.toString()
				key =
					if (text.trim().startsWith("{")) JSONObject(text).getString("descriptor")
					else text
				model.clearTools()
				true
			}
		}
	removal?.let { profile ->
		AlertDialog(
			onDismissRequest = { removal = null },
			title = { Text("Remove ${profile.name}?") },
			text = {
				Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
					Text(
						"This permanently removes this wallet’s local keys, account databases, Coinjoin state and Ark recovery data. No funds are transferred. External backups and node credentials are preserved.",
					)
					Text(
						if (profile.kind == "hot")
							"Finish pending operations and verify your seed and current encrypted full backup outside this app. Seed words alone may not recover Ark funds."
						else
							"Save the public descriptor or account export. Your hardware device is not erased.",
					)
					Row {
						Checkbox(backupAcknowledged, { backupAcknowledged = it })
						Text("I have verified the required recovery backup.")
					}
					OutlinedTextField(
						confirmation,
						{ confirmation = it },
						label = { Text("Type REMOVE ${profile.name}") },
					)
				}
			},
			confirmButton = {
				TextButton(
					onClick = {
						activity?.authenticateAction("Remove ${profile.name}") {
							model.removeWallet(profile, confirmation, backupAcknowledged)
							removal = null
							confirmation = ""
						}
					},
					enabled =
						backupAcknowledged && confirmation == "REMOVE ${profile.name}" && !s.busy,
				) {
					Text("Authenticate and remove")
				}
			},
			dismissButton = { TextButton(onClick = { removal = null }) { Text("Cancel") } },
		)
	}
}

@Composable
internal fun MessageSigning(s: WalletState, model: WalletModel) {
	var address by remember { mutableStateOf("") }
	var message by remember { mutableStateOf("") }
	val activity = LocalActivity.current as? MainActivity
	Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
		Text("Sign a message", style = MaterialTheme.typography.titleLarge)
		Text(
			"Prove ownership of an on-chain Taproot address using BIP322-simple. Only sign messages you understand; a signature can authorize actions on another service.",
		)
		OutlinedTextField(
			address,
			{
				address = it
				model.clearTools()
			},
			label = { Text("Your address") },
			modifier = Modifier.fillMaxWidth(),
		)
		OutlinedTextField(
			message,
			{
				message = it
				model.clearTools()
			},
			label = { Text("Exact message") },
			minLines = 4,
			modifier = Modifier.fillMaxWidth(),
		)
		Text("${message.toByteArray().size} / 4096 UTF-8 bytes · spaces and line breaks matter")
		Button(
			onClick = {
				val a = address.trim()
				val exact = message
				activity?.authenticateAction("Sign this exact message") {
					model.tool(
						"sign_message_onchain",
						JSONObject().put("address", a).put("message", exact),
					)
				}
			},
			enabled = !s.busy && address.isNotBlank() && message.toByteArray().size <= 4096,
		) {
			Text("Authenticate and sign")
		}
		s.toolsResult
			?.optString("signature")
			?.takeIf { it.isNotEmpty() }
			?.let { SelectionContainer { Text(it) } }
	}
}

@Composable
internal fun OnchainTools(s: WalletState, model: WalletModel) {
	var change by remember { mutableStateOf(false) }
	var start by remember { mutableStateOf(0) }
	var selectedAddress by remember { mutableStateOf("") }
	Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
		Text("On-chain accounts", style = MaterialTheme.typography.titleLarge)
		if (s.profiles.firstOrNull { it.id == s.activeID }?.kind == "hot")
			Row {
				listOf("taproot", "segwit").forEach { account ->
					OutlinedButton(
						onClick = {
							model.tool(
								"select_onchain_account",
								JSONObject().put("account", account),
							)
						},
						enabled = !s.busy,
					) {
						Text(account)
					}
				}
			}
		Text(
			"Switching address accounts does not move funds. Sync the selected account before sending.",
			style = MaterialTheme.typography.bodySmall,
		)
		Row {
			Text("Change addresses", Modifier.weight(1f))
			Switch(
				change,
				{
					change = it
					start = 0
					model.clearTools()
				},
			)
		}
		Button(
			onClick = {
				model.tool(
					"addresses_onchain",
					JSONObject().put("start", start).put("change", change),
				)
			},
			enabled = !s.busy,
		) {
			Text("Load addresses")
		}
		s.toolsResult?.optJSONArray("addresses")?.let { rows ->
			for (i in 0 until rows.length()) {
				val row = rows.getJSONObject(i)
				OutlinedButton(
					onClick = { selectedAddress = row.getString("address") },
					modifier = Modifier.fillMaxWidth(),
				) {
					Text(
						"${row.getInt("index")} · ${if(row.optBoolean("revealed"))"Revealed"else "Preview"}\n${row.getString("address")}",
					)
				}
			}
		}
		Text(
			"Previewing does not reserve addresses. Create a receive address when requesting payment so recovery can discover it reliably.",
			style = MaterialTheme.typography.bodySmall,
		)
		if (selectedAddress.isNotBlank()) {
			NodeReceiveCode(selectedAddress)
			SelectionContainer { Text(selectedAddress) }
			TextButton(onClick = { selectedAddress = "" }) { Text("Close address QR") }
		}
		TextButton(
			onClick = {
				start = (start - 20).coerceAtLeast(0)
				model.tool(
					"addresses_onchain",
					JSONObject().put("start", start).put("change", change),
				)
			},
			enabled = start > 0 && !s.busy,
		) {
			Text("Previous addresses")
		}
		if (s.toolsResult?.optBoolean("has_more") == true)
			TextButton(
				onClick = {
					start += 20
					model.tool(
						"addresses_onchain",
						JSONObject().put("start", start).put("change", change),
					)
				},
				enabled = !s.busy,
			) {
				Text("Next addresses")
			}
	}
}

@Composable
internal fun ArkMaintenance(s: WalletState, model: WalletModel) {
	val unit = LocalBitcoinUnit.current
	var amount by remember { mutableStateOf("") }
	var offerAmount by remember { mutableStateOf("") }
	var description by remember { mutableStateOf("Paperclip wallet") }
	val result = s.toolsResult
	Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
		Text("Board funds into Ark", style = MaterialTheme.typography.titleLarge)
		OutlinedTextField(
			amount,
			{
				amount = it
				model.clearTools()
			},
			label = { Text("Board amount in ${unit.title}") },
			modifier = Modifier.fillMaxWidth(),
		)
		Button(
			onClick = {
				unit
					.parse(amount)
					?.takeIf { it > 0 }
					?.let { model.tool("quote_board", JSONObject().put("amount_sat", it)) }
			},
			enabled = !s.busy && s.connected,
		) {
			Text("Review boarding")
		}
		if (result?.has("board_amount_sat") == true) {
			Text("Board amount: ${unit.display(result.getLong("board_amount_sat"))}")
			Text("Network fee: ${unit.display(result.getLong("network_fee_sat"))}")
			Text("Recovery reserve: ${unit.display(result.getLong("reserve_sat"))}")
			Text("Available in Ark: ${unit.display(result.getLong("net_sat"))}")
			Text(
				"Total debit: ${unit.display(result.getLong("total_sat"))}",
				style = MaterialTheme.typography.titleMedium,
			)
			Button(
				onClick = {
					model.tool(
						"board",
						JSONObject()
							.put("amount_sat", result.getLong("board_amount_sat"))
							.put("total_sat", result.getLong("total_sat")),
					)
				},
				enabled = !s.busy,
			) {
				Text("Confirm and board")
			}
		}
		HorizontalDivider()
		Text("Ark maintenance", style = MaterialTheme.typography.titleLarge)
		Text(
			"Keep funds current and recover interrupted receives. These actions do not create a new outgoing payment.",
		)
		OutlinedButton(onClick = model::refreshArk, enabled = s.connected && !s.busy) {
			Text("Refresh expiring funds")
		}
		OutlinedButton(onClick = { model.tool("recover") }, enabled = s.connected && !s.busy) {
			Text("Recover interrupted operations")
		}
		OutlinedButton(
			onClick = { model.tool("receive_pending") },
			enabled = s.connected && !s.busy,
		) {
			Text("Pending incoming invoices")
		}
		result?.optJSONArray("receives")?.let { rows ->
			for (i in 0 until rows.length()) {
				val row = rows.getJSONObject(i)
				val hash = row.getString("payment_hash")
				SelectionContainer {
					Text(row.getString("invoice"), style = MaterialTheme.typography.bodySmall)
				}
				Row {
					TextButton(
						onClick = {
							model.tool("receive_status", JSONObject().put("payment_hash", hash))
						},
						enabled = !s.busy,
					) {
						Text("Check status")
					}
					TextButton(
						onClick = {
							model.tool("receive_claim", JSONObject().put("payment_hash", hash))
						},
						enabled = !s.busy,
					) {
						Text("Claim received funds")
					}
				}
			}
		}
		result
			?.optString("state")
			?.takeIf { it.isNotEmpty() }
			?.let { Text(PaymentStatus.from(it).title) }
		HorizontalDivider()
		Text("Reusable Ark Lightning offer", style = MaterialTheme.typography.titleLarge)
		OutlinedTextField(
			offerAmount,
			{
				offerAmount = it
				model.clearTools()
			},
			label = { Text("Offer amount in ${unit.title} (optional)") },
			modifier = Modifier.fillMaxWidth(),
		)
		OutlinedTextField(
			description,
			{
				description = it
				model.clearTools()
			},
			label = { Text("Offer description") },
			modifier = Modifier.fillMaxWidth(),
		)
		Text(
			"Leave the amount empty for an amountless offer. Creating an offer does not send funds.",
			style = MaterialTheme.typography.bodySmall,
		)
		Button(
			onClick = {
				val fields = JSONObject().put("description", description)
				unit.parse(offerAmount)?.takeIf { it > 0 }?.let { fields.put("amount_sat", it) }
				model.tool("offer_create", fields)
			},
			enabled =
				s.connected &&
					!s.busy &&
					(offerAmount.isBlank() || (unit.parse(offerAmount) ?: 0) > 0),
		) {
			Text("Create offer")
		}
		Row {
			TextButton(onClick = { model.tool("offer_status") }, enabled = s.connected && !s.busy) {
				Text("Current offer")
			}
			TextButton(
				onClick = { model.tool("offer_disable") },
				enabled = s.connected && !s.busy,
			) {
				Text("Disable offer")
			}
		}
		result
			?.optString("offer")
			?.takeIf { it.isNotEmpty() }
			?.let {
				NodeReceiveCode(it)
				SelectionContainer { Text(it, style = MaterialTheme.typography.bodySmall) }
			}
	}
}
