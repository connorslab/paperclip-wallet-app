package xyz.paperclip.wallet

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

@Composable
internal fun WalletHealthPage(s: WalletState, model: WalletModel, navigate: (String) -> Unit) {
    val context = LocalContext.current
    val engine = WalletEngine.shared(context)
    val scope = rememberCoroutineScope()
    val profile = s.profiles.firstOrNull { it.id == s.activeID }
    var checking by remember { mutableStateOf(false) }
    var checked by remember(s.activeID) { mutableStateOf<Long?>(null) }
    var result by remember(s.activeID) { mutableStateOf("Connection not yet checked here") }
    var report by remember(s.activeID) { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        WalletColumns(primary = {
        CardBlock("Current wallet") {
            Text(profile?.name ?: "Selected wallet", style = MaterialTheme.typography.titleLarge)
            Text(if (s.network == "xbt-mainnet") "XBT mainnet" else "XBT regtest")
            Text(when(profile?.kind) { "hardware" -> "Signing: on your signer"; "watch" -> "Watch only"; else -> "Signing: on this device" })
            Text(result)
            Text("Displayed balances may be cached. Refresh before making decisions.", style = MaterialTheme.typography.bodySmall)
            OutlinedButton(enabled = !checking && !s.busy, onClick = {
                checking = true; checked = null; result = "Checking on-chain backend…"
                scope.launch {
                    try { PaymentGate.run {
                        check(engine.activeID() == s.activeID)
                        check(engine.call("chain_health").getBoolean("connected"))
                        checked = System.currentTimeMillis(); result = "On-chain backend responded at " + java.text.DateFormat.getTimeInstance().format(java.util.Date())
                    } }
                    catch (e: kotlinx.coroutines.CancellationException) { throw e }
                    catch (_: Exception) { result = "Could not verify the connection. Check Connections and try again." }
                    finally { checking = false }
                }
            }) { Text(if(checking) "Checking…" else "Check connection") }
            OutlinedButton(enabled = !s.busy && !checking, onClick = { model.sync() }) { Text("Refresh wallet") }
            TextButton(onClick = { navigate("Connections") }) { Text("Connection settings") }
        }
        }, secondary = {
        CardBlock("Recovery readiness") {
            if(profile?.kind == "hot") {
                Text("Back up after using Ark. Seed words alone do not include its recovery state.")
                TextButton(onClick = { navigate("Backup") }) { Text("Backup & recovery") }
            } else Text("Keep your signing seed on the signer and a copy of the public descriptor. A public descriptor restores monitoring, but cannot sign.")
            Text("Open a pending payment in Activity before trying another send. A fee increase keeps the original recipient and requires a new review.")
        }
        })
        CardBlock("Support report") {
            Text("Preview a technical summary without addresses, balances, payment details, names, server URLs, or credentials.")
            OutlinedButton(onClick = {
                val fresh = checked?.let { System.currentTimeMillis() - it in 0..75_000 } == true
                val kind = profile?.kind?.takeIf { it in listOf("hot", "hardware", "watch") } ?: "unknown"
                report = "Paperclip support report v1\nPlatform: Android\nBuild: ${BuildConfig.VERSION_CODE}\nNetwork: ${if(s.network == "xbt-mainnet") "mainnet" else "regtest"}\nWallet type: $kind\nOn-chain connection: ${if(fresh) "recently verified" else "not recently verified"}\nSecrets and financial details: excluded"
            }) { Text("Prepare support report") }
            if(report.isNotEmpty()) {
                SelectionContainer { Text(report, style = MaterialTheme.typography.bodySmall) }
                OutlinedButton(onClick = { context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type="text/plain";putExtra(Intent.EXTRA_TEXT,report) }, "Share report")) }) { Text("Share report…") }
            }
        }
    }
}
