package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable internal fun JarsSendPage(client: JoinBlaketClient, auth: JoinBlaketAuthorization, jar: Int, name: String,
	close: () -> Unit, activity: () -> Unit, bond: Pair<String, String>? = null) {
	var destination by remember { mutableStateOf("") }; var amount by remember { mutableStateOf("") }
	var rate by remember { mutableStateOf("1") }; var feeLimit by remember { mutableStateOf("1000") }
	var coinjoin by remember { mutableStateOf(false) }; var busy by remember { mutableStateOf(false) }
	var submitting by remember { mutableStateOf(false) }
	var attempted by remember { mutableStateOf(false) }; var message by remember { mutableStateOf<String?>(null) }
	var draft by remember { mutableStateOf<JoinBlaketSendDraft?>(null) }
	var review by remember { mutableStateOf<JoinBlaketSendReview?>(null) }
	var result by remember { mutableStateOf<JoinBlaketPayment?>(null) }
	val scroll = rememberScrollState()
	LaunchedEffect(review?.payment?.id, result?.state, attempted) { scroll.scrollTo(0) }
	val scope = rememberCoroutineScope()
	val focus = LocalFocusManager.current
	val keyboard = LocalSoftwareKeyboardController.current
	fun sats(value: Long) = java.text.NumberFormat.getIntegerInstance().format(value) + " sats"
	fun run(action: suspend () -> Unit) {
		if (busy) return
		focus.clearFocus(); keyboard?.hide()
		busy = true; message = null
		scope.launch {
			try { action() } catch (e: CancellationException) { throw e }
			catch (e: Exception) { message = e.message ?: "Check Jars payment activity before another action" }
			finally { busy = false }
		}
	}
	Column(Modifier.fillMaxHeight(0.94f).fillMaxWidth().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
			Text(if(bond == null) "Jar payment" else "Fund fidelity bond", style = MaterialTheme.typography.headlineSmall)
			TextButton(onClick = close) { Text("Close") }
		}
		Column(Modifier.weight(1f).verticalScroll(scroll).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
			WalletSurface {
				Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
					val saved = review; val terms = draft; val receipt = result
					when {
						saved != null && terms != null && receipt == null -> {
							Text(if(terms.bondLocktime == null) "Review jar payment" else "Review bond funding", style = MaterialTheme.typography.titleLarge)
							ReviewAmountHero(sats(terms.amountSat), name, if (terms.bondLocktime != null) "Amount to lock" else if (terms.coinjoin) "CoinJoin" else "Direct · no CoinJoin")
							val q = checkNotNull(saved.payment.quote)
							if (terms.coinjoin) {
								ReviewDetailRow("Maker fees", sats(checkNotNull(q.makerFeeSat)))
								ReviewDetailRow("Your mining fee", sats(checkNotNull(q.miningFeeSat)))
								Text("With ${q.makerCount} makers · sent through your Jam node", style = MaterialTheme.typography.bodySmall)
								Text("CoinJoin does not use RBF. Discarding a review may leave coins reserved briefly.", style = MaterialTheme.typography.bodySmall)
							} else ReviewDetailRow("Mining fee", sats(q.feeSat))
							ReviewDetailRow("Total debit", sats(q.totalSat), emphasized = true)
							if (terms.bondLocktime != null) {
								ReviewDetailRow("Bond unlock date",q.bondUnlockDescription)
								Text("These coins cannot be spent before the unlock date. Bond funding is public; earnings are not guaranteed.",style=MaterialTheme.typography.bodySmall)
							}
							Text(terms.destination, style = MaterialTheme.typography.bodySmall)
							Text("Wallet: ${auth.wallet}", style = MaterialTheme.typography.bodySmall)
							Text("Review expires " + java.time.Instant.ofEpochSecond(saved.expires).atZone(java.time.ZoneId.systemDefault()).toLocalTime().withNano(0), style = MaterialTheme.typography.bodySmall)
							WalletPrimaryButton(enabled = !busy, modifier = Modifier.fillMaxWidth(), onClick = { run { submitting = true; review = null; result = client.commitSend(saved,terms,auth) } }) { Text(if (terms.bondLocktime == null) "Send payment" else "Fund bond") }
							TextButton(enabled = !busy, onClick = { run { client.discardPayment(terms.id,auth); review = null; draft = null; attempted = false } }) { Text("Discard unsent review") }
						}
						receipt != null -> {
							Text(receipt.label, style = MaterialTheme.typography.titleLarge)
							Text(if (receipt.state == "submitted") "The transaction was submitted. Confirmation is still pending." else "The payment may have reached the network. Check its status before another action.")
							WalletPrimaryButton(onClick = activity, modifier = Modifier.fillMaxWidth()) { Text("View payment activity") }
						}
						busy && attempted -> {
							Text(if (submitting) "Submitting payment" else if (terms?.coinjoin == true) "Preparing CoinJoin" else "Preparing payment", style = MaterialTheme.typography.titleLarge)
							Text(if (submitting) "Waiting for your Jam node. Keep this screen open; the payment will not be sent again automatically." else if (terms?.coinjoin == true) "Finding participants and checking the exact fees. This can take up to three minutes. Nothing is broadcast until you review and send." else "Checking the recipient, coins and fees before review.")
						}
						attempted -> {
							Text("Check payment activity", style = MaterialTheme.typography.titleLarge)
							Text("A request was started. Its saved state must be checked before creating another payment.")
							WalletPrimaryButton(enabled = !busy, onClick = activity, modifier = Modifier.fillMaxWidth()) { Text("View payment activity") }
						}
						else -> {
							Text("${if(bond == null) "Send" else "Fund"} from $name", style = MaterialTheme.typography.titleLarge)
							if (bond != null) {
								Text("Unlocks ${bond.second}-01 at 00:00 UTC. Back up your Jam wallet first; these coins will be locked.")
								Text(bond.first,style=MaterialTheme.typography.bodySmall)
							} else OutlinedTextField(destination, { destination = it }, label = { Text("XBT address") }, modifier = Modifier.fillMaxWidth(), enabled = !busy)
							OutlinedTextField(amount, { amount = it }, label = { Text("Amount (sats)") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), enabled = !busy)
							if (bond == null) { Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) { Text("CoinJoin"); Switch(coinjoin, { coinjoin = it }, enabled = !busy, modifier = Modifier.testTag("jars-send-coinjoin")) }
							Text(if (coinjoin) "Pay with other participants. Review maker and mining fees before sending. If CoinJoin is unavailable, no direct payment is made." else "Direct payment. This transaction will not use CoinJoin.", style = MaterialTheme.typography.bodySmall) }
							OutlinedTextField(rate, { rate = it }, label = { Text("Mining rate (sat/vB)") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), enabled = !busy)
							OutlinedTextField(feeLimit, { feeLimit = it }, label = { Text("Maximum total fees (sats)") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), enabled = !busy)
							WalletPrimaryButton(enabled = !busy, modifier = Modifier.fillMaxWidth(), onClick = { run {
								val feeRate = rate.toLong(); require(feeRate in 1..10000)
								val value = JoinBlaketSendDraft(jar,bond?.first ?: destination.trim(),amount.toLong(),feeRate*1000,feeLimit.toLong(), coinjoin = coinjoin, bondLocktime = bond?.let { JoinBlaketBond.locktime(it.second) })
								submitting = false; draft = value; attempted = true; review = client.prepareSend(value,auth)
							} }) { Text("Review payment") }
						}
					}
				}
			}
			if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
			message?.let { Text(it) }
		}
	}
}
