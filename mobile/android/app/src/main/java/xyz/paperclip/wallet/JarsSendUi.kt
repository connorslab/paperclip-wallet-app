package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable internal fun JarsSendPage(client: JoinBlaketClient, auth: JoinBlaketAuthorization, jar: Int, name: String,
	close: () -> Unit, activity: () -> Unit) {
	var destination by remember { mutableStateOf("") }; var amount by remember { mutableStateOf("") }
	var rate by remember { mutableStateOf("1") }; var feeLimit by remember { mutableStateOf("1000") }
	var coinjoin by remember { mutableStateOf(false) }; var busy by remember { mutableStateOf(false) }
	var attempted by remember { mutableStateOf(false) }; var message by remember { mutableStateOf<String?>(null) }
	var draft by remember { mutableStateOf<JoinBlaketSendDraft?>(null) }
	var review by remember { mutableStateOf<JoinBlaketSendReview?>(null) }
	var result by remember { mutableStateOf<JoinBlaketPayment?>(null) }
	val scope = rememberCoroutineScope()
	fun run(action: suspend () -> Unit) {
		if (busy) return
		busy = true; message = null
		scope.launch {
			try { action() } catch (e: CancellationException) { throw e }
			catch (e: Exception) { message = e.message ?: "Check Jars payment activity before another action" }
			finally { busy = false }
		}
	}
	Column(Modifier.fillMaxHeight(0.94f).fillMaxWidth().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
			Text("Jar payment", style = MaterialTheme.typography.headlineSmall)
			TextButton(onClick = close) { Text("Close") }
		}
		Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
			WalletSurface {
				Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
					val saved = review; val terms = draft; val receipt = result
					when {
						saved != null && terms != null && receipt == null -> {
							Text("Review jar payment", style = MaterialTheme.typography.titleLarge)
							ReviewAmountHero("${terms.amountSat} sats", name, "Direct · no CoinJoin")
							val q = checkNotNull(saved.payment.quote)
							ReviewDetailRow("Mining fee", "${q.feeSat} sats")
							ReviewDetailRow("Total debit", "${q.totalSat} sats", emphasized = true)
							Text(terms.destination, style = MaterialTheme.typography.bodySmall)
							Text("Wallet: ${auth.wallet}", style = MaterialTheme.typography.bodySmall)
							Text("Review expires " + java.time.Instant.ofEpochSecond(saved.expires).atZone(java.time.ZoneId.systemDefault()).toLocalTime().withNano(0), style = MaterialTheme.typography.bodySmall)
							WalletPrimaryButton(enabled = !busy, modifier = Modifier.fillMaxWidth(), onClick = { run { review = null; result = client.commitSend(saved,terms,auth) } }) { Text("Send payment") }
							TextButton(enabled = !busy, onClick = { run { client.discardPayment(terms.id,auth); review = null; draft = null; attempted = false } }) { Text("Discard unsent review") }
						}
						receipt != null -> {
							Text(receipt.label, style = MaterialTheme.typography.titleLarge)
							Text(if (receipt.state == "submitted") "The transaction was submitted. Confirmation is still pending." else "The payment may have reached the network. Check its status before another action.")
							WalletPrimaryButton(onClick = activity, modifier = Modifier.fillMaxWidth()) { Text("View payment activity") }
						}
						attempted -> {
							Text("Check payment activity", style = MaterialTheme.typography.titleLarge)
							Text("A request was started. Its saved state must be checked before creating another payment.")
							WalletPrimaryButton(enabled = !busy, onClick = activity, modifier = Modifier.fillMaxWidth()) { Text("View payment activity") }
						}
						else -> {
							Text("Send from $name", style = MaterialTheme.typography.titleLarge)
							OutlinedTextField(destination, { destination = it }, label = { Text("XBT address") }, modifier = Modifier.fillMaxWidth(), enabled = !busy)
							OutlinedTextField(amount, { amount = it }, label = { Text("Amount (sats)") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), enabled = !busy)
							Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) { Text("CoinJoin"); Switch(coinjoin, { coinjoin = it }, enabled = !busy, modifier = Modifier.testTag("jars-send-coinjoin")) }
							Text(if (coinjoin) "CoinJoin sends require the reviewed CoinJoin integration. It is not available on this build. Your choice will never fall back to a direct send." else "Direct payment. This transaction will not use CoinJoin.", style = MaterialTheme.typography.bodySmall)
							OutlinedTextField(rate, { rate = it }, label = { Text("Mining rate (sat/vB)") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), enabled = !busy)
							OutlinedTextField(feeLimit, { feeLimit = it }, label = { Text("Maximum mining fee (sats)") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), enabled = !busy)
							WalletPrimaryButton(enabled = !busy && !coinjoin, modifier = Modifier.fillMaxWidth(), onClick = { run {
								val feeRate = rate.toLong(); require(feeRate in 1..10000 && !coinjoin)
								val value = JoinBlaketSendDraft(jar,destination.trim(),amount.toLong(),feeRate*1000,feeLimit.toLong())
								draft = value; attempted = true; review = client.prepareSend(value,auth)
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
