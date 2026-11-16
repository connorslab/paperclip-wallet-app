package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONObject

@Composable
internal fun FeeReplacementControl(txid: String, walletID: String) {
    val engine = WalletEngine.shared(LocalContext.current)
    val scope = rememberCoroutineScope()
    var expanded by remember(txid, walletID) { mutableStateOf(false) }
    var review by remember(txid, walletID) { mutableStateOf<JSONObject?>(null) }
    var customFee by remember(txid, walletID) { mutableStateOf(false) }
    var fee by remember(txid, walletID) { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember(txid, walletID) { mutableStateOf("") }
    fun perform(action: suspend () -> Unit) {
        if (busy) return
        busy = true; message = ""
        scope.launch {
            try { PaymentGate.run { check(engine.activeID() == walletID) { "Wallet changed. Review again." }; action() } }
            catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (e: Exception) { message = e.message ?: "Check payment status before another action." }
            finally { busy = false }
        }
    }
    TextButton(onClick = { expanded = !expanded }, enabled = !busy) { Text(if(expanded) "Hide payment assistance" else "Payment assistance") }
    if (!expanded) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("An unconfirmed payment is still in progress. Do not send it again.")
        TextButton(onClick = { customFee = !customFee; if (!customFee) { fee = ""; review = null } }, enabled = !busy) { Text(if (customFee) "Hide custom fee" else "Choose a custom fee") }
        if (customFee) OutlinedTextField(fee, { fee = it; review = null }, label = { Text("New total fee in sats (optional)") }, enabled = !busy, modifier = Modifier.fillMaxWidth())
        Text("Leave blank to review twice the original fee. Confirmation time is not guaranteed.", style = MaterialTheme.typography.bodySmall)
        OutlinedButton(enabled = !busy, onClick = {
            review = null
            perform {
                require(fee.isEmpty() || fee.matches(Regex("[0-9]+"))) { "Enter a total fee in whole sats." }
                val amount = if (fee.isEmpty()) 0 else fee.toLongOrNull() ?: error("Fee is too large")
                val data = engine.call("replacement_prepare", JSONObject().put("txid", txid).put("new_fee_sat", amount))
                FeeReplacementReview.validate(data, txid)
                review = data
            }
        }) { Text(if (busy) "Checking payment…" else "Review fee increase") }
        if (message.isNotEmpty()) SelectionContainer { Text(message) }
    }
    review?.let { data ->
        AlertDialog(onDismissRequest = { review = null }, title = { Text("Review fee replacement") },
            text = { SelectionContainer(Modifier.verticalScroll(rememberScrollState())) { Text(buildString {
                val recipients = data.getJSONArray("recipients")
                for (i in 0 until recipients.length()) {
                    val recipient = recipients.getJSONObject(i)
                    append("Recipient: ").append(recipient.getLong("amount_sat")).append(" sats\n").append(recipient.getString("address")).append("\n\n")
                }
                append("Original fee: ").append(data.getLong("old_fee_sat")).append(" sats\nNew total fee: ").append(data.getLong("new_fee_sat"))
                append(" sats\nAdditional debit: ").append(data.getLong("additional_fee_sat")).append(" sats\n\nRecipients and amounts stay the same. Confirmation is still required.")
            }) } },
            dismissButton = { TextButton(onClick = { review = null }) { Text("Cancel") } },
            confirmButton = { TextButton(enabled = !busy, onClick = {
                review = null
                perform {
                    val result = engine.call("replacement_commit", JSONObject().put("replacement_txid", data.getString("replacement_txid")).put("new_fee_sat", data.getLong("new_fee_sat")))
                    message = (if (result.optString("state") == "submitted") "Replacement submitted. Awaiting confirmation." else "Replacement saved. Broadcast is not confirmed; check status before another action.") + "\n" + result.optString("txid")
                }
            }) { Text("Increase fee") } },
        )
    }
}

@Composable
internal fun OwnedWalletDestination(s: WalletState, address: String, choose: (String) -> Unit) {
    val engine = WalletEngine.shared(LocalContext.current)
    val scope = rememberCoroutineScope()
    var expanded by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var selected by remember(s.activeID) { mutableStateOf<Pair<String, String>?>(null) }
    var error by remember { mutableStateOf("") }
    val latestAddress by rememberUpdatedState(address)
    val targets = s.profiles.filter { it.id != s.activeID && it.network == s.network }
    if (targets.isEmpty()) return
    Box {
        TextButton(onClick = { expanded = true }, enabled = !busy && !s.busy) { Text("Move to my other wallet") }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            targets.forEach { profile -> DropdownMenuItem(text = { Column {
                Text(profile.name)
                Text(when(profile.kind) { "hardware" -> "QR signer"; "watch" -> "Watch only"; else -> "Hot wallet" }, style = MaterialTheme.typography.bodySmall)
            } }, onClick = {
                expanded = false; busy = true; error = ""
                scope.launch {
                    try { PaymentGate.run {
                        check(engine.activeID() == s.activeID) { "Source wallet changed" }
                        val before = latestAddress
                        val value = engine.walletDestinationAddress(profile.id)
                        check(latestAddress == before) { "Recipient changed. Choose the destination wallet again." }
                        selected = profile.name to value; choose(value)
                    } }
                    catch (e: kotlinx.coroutines.CancellationException) { throw e }
                    catch (e: Exception) { error = e.message ?: "Could not read destination wallet" }
                    finally { busy = false }
                }
            }) }
        }
    }
    selected?.takeIf { it.second == address }?.let {
        Text("From " + (s.profiles.firstOrNull { p -> p.id == s.activeID }?.name ?: "selected wallet") + " to " + it.first)
        Text("On-chain transfer. Network fees apply. Verify a hardware wallet’s receiving address on its signer before approval.", style = MaterialTheme.typography.bodySmall)
    }
    if (error.isNotEmpty()) Text(error)
}
