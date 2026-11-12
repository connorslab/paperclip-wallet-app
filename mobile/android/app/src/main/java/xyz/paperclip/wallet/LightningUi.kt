package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
internal fun NodeLightning(model: LightningModel) {
	val unit = LocalBitcoinUnit.current
	val s by model.state.collectAsStateWithLifecycle()
	val torStatus by EmbeddedTor.status.collectAsStateWithLifecycle()
	var page by remember { mutableStateOf("balance") }
	var endpoint by remember(s.connection) { mutableStateOf(s.connection.endpoint) }
	var credential by remember(s.connection) { mutableStateOf(s.connection.credential) }
	var pin by remember(s.connection) { mutableStateOf(s.connection.pin) }
	var implementation by remember(s.connection) { mutableStateOf(s.connection.implementation) }
	var tor by remember(s.connection) { mutableStateOf(s.connection.proxy.isNotEmpty()) }
	var builtin by
		remember(s.connection) {
			mutableStateOf(s.connection.proxy == "builtin" || s.connection.proxy.isEmpty())
		}
	var proxy by
		remember(s.connection) {
			mutableStateOf(
				s.connection.proxy.takeUnless { it == "builtin" } ?: "socks5h://127.0.0.1:9050",
			)
		}
	var invoice by remember { mutableStateOf("") }
	var amount by remember { mutableStateOf("") }
	var fee by remember { mutableStateOf(unit.input(100)) }
	var offer by remember { mutableStateOf(false) }
	var scanning by remember { mutableStateOf(false) }
	if (scanning)
		QrScanner(onClose = { scanning = false }) { frame ->
			invoice = PaymentInput.scan(frame).destination
			model.clearReview()
			true
		}
	var description by remember { mutableStateOf("Paperclip wallet") }
	fun navigate(p: String) {
		model.clearReview()
		page = p
	}
	if (s.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
	if (s.message.isNotEmpty()) Text(s.message, color = MaterialTheme.colorScheme.error)
	Card(Modifier.fillMaxWidth()) {
		Column(Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
			when (page) {
				"connection" -> {
					Text("Node connection", style = MaterialTheme.typography.titleLarge)
					Row {
						listOf("lnd", "cln").forEach { kind ->
							FilterChip(
								selected = implementation == kind,
								onClick = { implementation = kind },
								label = { Text(kind.uppercase()) },
							)
						}
					}
					OutlinedTextField(
						endpoint,
						{ endpoint = it },
						label = { Text("REST endpoint · HTTPS or Tor onion") },
						modifier = Modifier.fillMaxWidth(),
					)
					OutlinedTextField(
						credential,
						{ credential = it },
						label = { Text(if (implementation == "lnd") "Macaroon (hex)" else "Rune") },
						visualTransformation = PasswordVisualTransformation(),
						modifier = Modifier.fillMaxWidth(),
					)
					OutlinedTextField(
						pin,
						{ pin = it },
						label = { Text("TLS certificate SHA256") },
						modifier = Modifier.fillMaxWidth(),
					)
					Row {
						Text("Use Tor", Modifier.weight(1f))
						Switch(tor, { tor = it })
					}
					if (tor) {
						Row {
							Text("Built-in Tor", Modifier.weight(1f))
							Switch(builtin, { builtin = it })
						}
						if (builtin) Text(torStatus, style = MaterialTheme.typography.bodySmall)
						else
							OutlinedTextField(
								proxy,
								{ proxy = it },
								label = { Text("SOCKS proxy · socks5h://host:port") },
								modifier = Modifier.fillMaxWidth(),
							)
					}
					Button(
						onClick = {
							model.connect(
								NodeConnection(
									implementation,
									endpoint.trim(),
									credential.trim(),
									pin.trim(),
									if (tor) {
										if (builtin) "builtin" else proxy.trim()
									} else "",
								),
							)
						},
						enabled = !s.busy,
					) {
						Text("Save and connect")
					}
					Text(
						"Credentials stay in encrypted device storage. A failed request never falls back to a direct connection.",
						style = MaterialTheme.typography.bodySmall,
					)
				}
				"receive" -> {
					Text("Receive on your node", style = MaterialTheme.typography.titleLarge)
					Row {
						Text("Reusable BOLT12 offer", Modifier.weight(1f))
						Switch(
							offer,
							{
								offer = it
								model.clearReview()
							},
						)
					}
					OutlinedTextField(
						amount,
						{
							amount = it
							model.clearReview()
						},
						label = {
							Text(
								if (offer) "Amount in ${unit.title} (optional)"
								else "Amount in ${unit.title}",
							)
						},
						modifier = Modifier.fillMaxWidth(),
					)
					if (offer)
						OutlinedTextField(
							description,
							{
								description = it
								model.clearReview()
							},
							label = { Text("Description") },
							modifier = Modifier.fillMaxWidth(),
						)
					Button(
						onClick = { model.receive(unit.backendAmount(amount), offer, description) },
						enabled = s.connected && !s.busy,
					) {
						Text(if (offer) "Create offer" else "Create invoice")
					}
					if (s.invoice.isNotEmpty()) {
						NodeReceiveCode(s.invoice)
						SelectionContainer {
							Text(s.invoice, style = MaterialTheme.typography.bodySmall)
						}
					}
				}
				"pay" -> {
					val review = s.review
					if (review == null) {
						Text("Pay from your node", style = MaterialTheme.typography.titleLarge)
						OutlinedTextField(
							invoice,
							{
								invoice = it
								model.clearReview()
							},
							label = { Text("BOLT11 invoice or BOLT12 offer/invoice") },
							modifier = Modifier.fillMaxWidth(),
						)
						TextButton(onClick = { scanning = true }, enabled = !s.busy) {
							Text("Scan invoice or offer")
						}
						OutlinedTextField(
							amount,
							{
								amount = it
								model.clearReview()
							},
							label = { Text("Amount in ${unit.title} (amountless offer)") },
							modifier = Modifier.fillMaxWidth(),
						)
						OutlinedTextField(
							fee,
							{
								fee = it
								model.clearReview()
							},
							label = { Text("Maximum routing fee in ${unit.title}") },
							modifier = Modifier.fillMaxWidth(),
						)
						Button(
							onClick = {
								model.review(
									invoice,
									unit.backendAmount(amount),
									unit.backendAmount(fee),
								)
							},
							enabled = s.connected && !s.busy,
						) {
							Text("Review payment")
						}
					} else {
						Text("Review payment", style = MaterialTheme.typography.titleLarge)
						Text("Amount: ${unit.displayMsat(review.msat)}")
						Text("Maximum fee: ${unit.display(review.feeSat)}")
						SelectionContainer {
							Text(review.invoice, style = MaterialTheme.typography.bodySmall)
						}
						Text("Confirm only if this invoice and amount are correct.")
						Button(
							onClick = {
								model.send()
								page = "status"
							},
							enabled = !s.busy && review.valid(),
						) {
							Text("Confirm and pay")
						}
						TextButton(onClick = model::clearReview, enabled = !s.busy) {
							Text("Cancel")
						}
					}
				}
				"status" -> {
					Text("Outgoing node payment", style = MaterialTheme.typography.titleLarge)
					val p = s.pending
					if (p == null) Text("No recorded outgoing node payment.")
					else {
						Text(
							when (p.optString("state")) {
								"succeeded" -> "Payment successful"
								"failed" -> "Payment failed"
								else -> "Payment needs checking"
							},
						)
						Text("Amount: ${unit.displayMsat(nodeAmount(p.get("amount_msat")))}")
						Button(onClick = model::checkPayment, enabled = s.connected && !s.busy) {
							Text("Check now")
						}
					}
					Text(
						"This status tracks outgoing payments from your node. Ark sends and incoming invoices have separate histories.",
						style = MaterialTheme.typography.bodySmall,
					)
				}
				else -> {
					val b = s.balance
					Text(
						if (b?.local != null) "Funds in active channels" else "Available to send",
						style = MaterialTheme.typography.titleMedium,
					)
					Text(
						b?.let { unit.displayMsat(it.local ?: it.sendable) } ?: "—",
						style = MaterialTheme.typography.headlineLarge,
					)
					UsdValue(b?.let { (it.local ?: it.sendable) / 1000 }, mainnet = s.mainnet)
					if (b != null) {
						Text("Available to send: ${unit.displayMsat(b.sendable)}")
						if (b.local != null && b.local > b.sendable)
							Text(
								"Your funds are still in your channels. Channel reserves limit how much you can send.",
								style = MaterialTheme.typography.bodySmall,
							)
						Text(
							"Receive capacity: ${unit.displayMsat(b.receivable)} · ${b.channels} active channels",
						)
						b.reserve?.let {
							Text(
								"Required channel reserves: ${unit.displayMsat(it)}",
								style = MaterialTheme.typography.bodySmall,
							)
						}
					}
					Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
						Button(onClick = { navigate("pay") }, enabled = s.connected && !s.busy) {
							Text("Pay")
						}
						Button(
							onClick = { navigate("receive") },
							enabled = s.connected && !s.busy,
						) {
							Text("Receive")
						}
					}
					TextButton(onClick = model::refresh, enabled = s.connected && !s.busy) {
						Text("Refresh balance")
					}
				}
			}
			if (page != "balance")
				TextButton(onClick = { navigate("balance") }, enabled = !s.busy) {
					Text("Back to balance")
				}
			if (page != "connection")
				TextButton(onClick = { navigate("connection") }, enabled = !s.busy) {
					Text("Node connection")
				}
			if (page != "status")
				TextButton(onClick = { navigate("status") }, enabled = !s.busy) {
					Text("Payment status")
				}
		}
	}
}

@Composable
internal fun NodeReceiveCode(value: String) {
	val qr =
		remember(value) {
			runCatching {
				val bits =
					com.google.zxing.qrcode
						.QRCodeWriter()
						.encode(value, com.google.zxing.BarcodeFormat.QR_CODE, 640, 640)
				android.graphics.Bitmap.createBitmap(
						640,
						640,
						android.graphics.Bitmap.Config.ARGB_8888,
					)
					.apply {
						val pixels =
							IntArray(640 * 640) {
								if (bits[it % 640, it / 640]) android.graphics.Color.BLACK
								else android.graphics.Color.WHITE
							}
						setPixels(pixels, 0, 640, 0, 0, 640, 640)
					}
			}
				.getOrNull()
		}
	if (qr != null)
		androidx.compose.foundation.Image(
			qr.asImageBitmap(),
			"Receive QR code",
			Modifier.fillMaxWidth().aspectRatio(1f),
		)
	else Text("This request is too long for a single QR code. Copy the text instead.")
}
