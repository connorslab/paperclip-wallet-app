package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
internal fun NodeLightning(model: LightningModel, initialPage: String = "balance", onPageChanged: (String) -> Unit = {}) {
	val unit = LocalBitcoinUnit.current
	val focus = LocalFocusManager.current
	val s by model.state.collectAsStateWithLifecycle()
	val torStatus by EmbeddedTor.status.collectAsStateWithLifecycle()
	var page by rememberSaveable { mutableStateOf(initialPage) }
	LaunchedEffect(initialPage) { page = initialPage }
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
		focus.clearFocus()
		model.clearReview()
		page = p
		onPageChanged(p)
	}
	BackHandler(page != "balance") { if (!s.busy) navigate("balance") }
	if (s.connecting || s.balanceStale || page == "connection") {
		HingeSafeContent {
		Card(
			Modifier.fillMaxWidth(),
			border = BorderStroke(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = .09f)),
			shape = RoundedCornerShape(26.dp),
			colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
		) {
			Column(Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
				Text(s.connectionStatus, style = MaterialTheme.typography.titleMedium)
				Text((if (s.connection.implementation == "cln") "Core Lightning" else "LND") +
					if (s.connection.proxy.isEmpty()) " · Direct HTTPS" else " · Through Tor",
					style = MaterialTheme.typography.bodySmall)
				s.checkedAt?.let { Text("Last verified " + java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(it)), style = MaterialTheme.typography.bodySmall) }
				if (s.connecting) TextButton(onClick = model::cancelConnection) { Text("Cancel connection") }
				if (s.balanceStale) Text("Last known balance · refresh to check your node", style = MaterialTheme.typography.bodySmall)
				TextButton(onClick = model::refresh, enabled = !s.busy && s.connection.endpoint.isNotBlank()) { Text("Reconnect saved node") }
			}
		}
	}
	}
	if (page != "balance") TextButton(onClick = { navigate("balance") }, enabled = !s.busy) { Text("Back to balance") }
	if (s.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
	if (s.message.isNotEmpty()) HingeSafeContent { Text(s.message, color = MaterialTheme.colorScheme.error) }
	HingeSafeContent(enabled = page != "connection") {
	Card(
			Modifier.fillMaxWidth(),
			border = BorderStroke(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = .09f)),
			shape = RoundedCornerShape(26.dp),
			colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
		) {
		Column(Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
			AnimatedContent(targetState = page, transitionSpec = {
				val direction = if (targetState == "balance") -1 else 1
				(fadeIn(tween(120)) + slideInHorizontally(tween(190, easing = FastOutSlowInEasing)) { it / 14 * direction }) togetherWith
					(fadeOut(tween(90)) + slideOutHorizontally(tween(150)) { -it / 18 * direction })
			}, label = "node-page") { visiblePage ->
			Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
			when (visiblePage) {
				"connection" -> {
					val pending = s.pending?.optString("state")?.let { it !in listOf("succeeded", "failed") } ?: false
					val editable = !s.busy && !pending
					Text("Your Lightning node", style = MaterialTheme.typography.titleLarge)
					WalletColumns(primary = {
					Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
						listOf("lnd", "cln").forEach { kind ->
							FilterChip(
								selected = implementation == kind,
								enabled = editable,
								onClick = { implementation = kind },
								label = { Text(kind.uppercase()) },
							)
						}
					}
					OutlinedTextField(
						endpoint,
						{ endpoint = it },
						label = { Text("REST address") },
						placeholder = { Text(if (implementation == "cln") "https://your-node:3010" else "https://your-node:8180") },
						modifier = Modifier.fillMaxWidth(),
						shape = RoundedCornerShape(16.dp),
						enabled = editable,
					)
					OutlinedTextField(
						credential,
						{ credential = it },
						label = { Text(if (implementation == "lnd") "Macaroon (hex)" else "Rune") },
						visualTransformation = PasswordVisualTransformation(),
						modifier = Modifier.fillMaxWidth(),
						shape = RoundedCornerShape(16.dp),
						enabled = editable,
					)
					}, secondary = {
					Text("Privacy & verification", style = MaterialTheme.typography.titleMedium)
					OutlinedTextField(
						pin,
						{ pin = it },
						label = { Text("Certificate fingerprints · optional") },
						supportingText = { Text("Separate trusted SHA256 fingerprints with commas.") },
						modifier = Modifier.fillMaxWidth(),
						shape = RoundedCornerShape(16.dp),
						enabled = editable,
					)
					Row {
						Text("Use Tor", Modifier.weight(1f))
						Switch(tor, { tor = it }, enabled = editable)
					}
					if (tor) {
						Row {
							Text("Built-in Tor", Modifier.weight(1f))
							Switch(builtin, { builtin = it }, enabled = editable)
						}
						if (builtin) Text(torStatus, style = MaterialTheme.typography.bodySmall)
						else
							OutlinedTextField(
								proxy,
								{ proxy = it },
								label = { Text("SOCKS proxy · socks5h://host:port") },
								modifier = Modifier.fillMaxWidth(),
								shape = RoundedCornerShape(16.dp),
						enabled = editable,
							)
					}
					})
					HingeSafeContent(limitWidth = false) {
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
						enabled = editable,
					) {
						Text("Verify and save connection")
					}
					}
					if (pending) Text("Resolve the saved payment before changing nodes. Reconnect above to check its status.")
					Text(
						"Credentials stay on this device.",
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
						shape = RoundedCornerShape(16.dp),
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
							shape = RoundedCornerShape(16.dp),
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
							shape = RoundedCornerShape(16.dp),
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
							shape = RoundedCornerShape(16.dp),
						)
						OutlinedTextField(
							fee,
							{
								fee = it
								model.clearReview()
							},
							label = { Text("Maximum routing fee in ${unit.title}") },
							modifier = Modifier.fillMaxWidth(),
							shape = RoundedCornerShape(16.dp),
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
						NodePaymentReview(review, unit, s.busy,
							onConfirm = { model.send(); page = "status"; onPageChanged("status") },
							onEdit = model::clearReview)
					}
				}
				"details" -> {
					Text("Channel balance", style = MaterialTheme.typography.titleLarge)
					s.balance?.let { b ->
						Text("Available to send: ${unit.displayMsat(b.sendable)}")
						Text("Receive capacity: ${unit.displayMsat(b.receivable)}")
						Text("Active channels: ${b.channels}")
						b.local?.let { Text("Funds in active channels: ${unit.displayMsat(it)}") }
						b.reserve?.let { Text("Required channel reserves: ${unit.displayMsat(it)}") }
						Text("Reserves stay in each channel. Routes, liquidity, and fees can limit individual payments.", style = MaterialTheme.typography.bodySmall)
					} ?: Text("Refresh to load channel balances.")
					TextButton(onClick = model::refresh, enabled = !s.busy) { Text("Refresh balance") }
				}
				"status" -> {
					Text("Outgoing node payment", style = MaterialTheme.typography.titleLarge)
					if (s.pending?.optString("state") == "succeeded") VerifiedPaymentCelebration()
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
			}
			}
			if (page == "balance") TextButton(onClick = { navigate("details") }, enabled = !s.busy) { Text("Balance details") }
			if (page == "balance")
				TextButton(onClick = { navigate("connection") }, enabled = !s.busy) {
					Text("Node connection")
				}
			if (page == "balance")
				TextButton(onClick = { navigate("status") }, enabled = !s.busy) {
					Text("Payment status")
				}
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
	if (qr != null) {
		Box(Modifier.fillMaxWidth(), contentAlignment = androidx.compose.ui.Alignment.Center) {
			androidx.compose.foundation.Image(
				qr.asImageBitmap(), "Receive QR code",
				Modifier.widthIn(max = 320.dp).fillMaxWidth().aspectRatio(1f),
			)
		}
	} else Text("This request is too long for a single QR code. Copy the text instead.")
}

@Composable
internal fun NodePaymentReview(review: NodeInvoiceReview, unit: BitcoinUnit, busy: Boolean, onConfirm: () -> Unit, onEdit: () -> Unit) {
	Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(20.dp)) {
		ReviewAmountHero(unit.displayMsat(review.msat), "Lightning node")
		ReviewDetailRow("Maximum routing fee", unit.display(review.feeSat))
		var showInvoice by remember(review.hash) { mutableStateOf(false) }
		TextButton(onClick = { showInvoice = !showInvoice }) { Text(if (showInvoice) "Hide invoice" else "View full invoice") }
		if (showInvoice) SelectionContainer { Text(review.invoice, style = MaterialTheme.typography.bodySmall) }
		Text("Confirm only if this invoice and amount are correct.", style = MaterialTheme.typography.bodySmall,
			color = MaterialTheme.colorScheme.onSurfaceVariant)
		Button(onClick = onConfirm, enabled = !busy && review.valid(), modifier = Modifier.fillMaxWidth()) { Text("Confirm and pay") }
		TextButton(onClick = onEdit, enabled = !busy) { Text("Edit invoice or fee") }
	}
}
