package xyz.paperclip.wallet

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter

private val Orange = Color(0xfff56835)
private val Navy = Color(0xff111c2e)
private val Panel = Color(0xff1a293e)

@Composable fun PaperclipApp(model: WalletModel, unlocked: Boolean, authError: String, unlock: () -> Unit) {
    val s by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val preferences = remember { context.getSharedPreferences("appearance", Context.MODE_PRIVATE) }
    var appearance by remember { mutableStateOf(preferences.getString("mode", "System") ?: "System") }
    val dark = appearance == "Dark" || (appearance == "System" && isSystemInDarkTheme())
    val colors = if (dark) darkColorScheme(primary = Orange, background = Navy, surface = Panel,
        onPrimary = Color.White, onSurface = Color(0xfff1f4fa), onBackground = Color(0xfff1f4fa), onSurfaceVariant = Color(0xffafbdd1), secondary = Orange, secondaryContainer = Color(0xff49332c),
        onSecondaryContainer = Color(0xffffba9d), surfaceVariant = Color(0xff293b54))
        else lightColorScheme(primary = Color(0xffb93c0c), background = Color(0xfff2f5fa), surface = Color.White,
            secondary = Color(0xffac390f), secondaryContainer = Color(0xffffdbc9), onSecondaryContainer = Color(0xff6e280e))
    MaterialTheme(colorScheme = colors, shapes = Shapes(large = RoundedCornerShape(26.dp))) {
        if (!unlocked) {
            Surface(Modifier.fillMaxSize(), color = colors.background) {
                Column(Modifier.padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    Brand(); Spacer(Modifier.height(40.dp)); Icon(Icons.Default.Lock, null, Modifier.size(56.dp), tint = Orange)
                    Text("Your XBT. Your keys.", style = MaterialTheme.typography.headlineSmall)
                    Spacer(Modifier.height(24.dp)); Button(onClick = unlock) { Text("Unlock Paperclip") }
                    Text("A device screen lock is required.", Modifier.padding(16.dp))
                    if (authError.isNotEmpty()) Text(authError, color = colors.error)
                }
            }
            return@MaterialTheme
        }
        var route by rememberSaveable { mutableStateOf("Wallet") }
        var tab by rememberSaveable { mutableStateOf("Wallet") }
        val scroll = remember(route, s.hasWallet) { ScrollState(0) }
        fun navigate(next: String) { model.cancelReview(); model.clearReceive(); route = next }
        BackHandler(route != tab && !s.busy) { navigate(tab) }
        Scaffold(containerColor = colors.background, bottomBar = {
            if (s.hasWallet) NavigationBar(containerColor = colors.surface) {
                listOf("Wallet" to Icons.Default.AccountBalanceWallet, "Lightning" to Icons.Default.Bolt,
                    "Activity" to Icons.Default.History, "Settings" to Icons.Default.Tune).forEach { (label, icon) ->
                    NavigationBarItem(modifier = Modifier.testTag("tab-$label"), selected = tab == label, enabled = !s.busy,
                        onClick = { tab = label; navigate(label) }, icon = { Icon(icon, label) }, label = { Text(label) })
                }
            }
        }) { inset ->
            Column(Modifier.fillMaxSize().padding(inset).imePadding()) {
                if (s.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (!s.loaded) { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }; return@Column }
                Column(Modifier.fillMaxSize().verticalScroll(scroll).padding(horizontal = 22.dp, vertical = 22.dp),
                    verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    if (!s.hasWallet) Setup(model, s, scroll) else {
                        if (route == tab) Brand() else Row(verticalAlignment = Alignment.CenterVertically) {
                            IconButton(onClick = { navigate(tab) }, enabled = !s.busy) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                            Text(route, style = MaterialTheme.typography.headlineSmall)
                        }
                        s.error?.let { CardBlock("Needs attention") { Text(it, color = colors.error) } }
                        AnimatedContent(targetState = route, label = "navigation") { page ->
                            Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
                                when (page) {
                                    "Wallet" -> Dashboard(s, model, ::navigate)
                                    "Send" -> Send(s, model)
                                    "Receive" -> Receive(s, model)
                                    "Lightning" -> Lightning(::navigate)
                                    "Activity" -> Activity(s, model)
                                    "Settings" -> {
                                        CardBlock("Your wallet") {
                                            Text(if (s.network == "xbt-mainnet") "XBT mainnet wallet" else "Regtest development wallet", style = MaterialTheme.typography.titleMedium)
                                            Text("Keep your recovery words and a current encrypted full backup somewhere safe.")
                                        }
                                        NavCard("Connection settings", "Chain backend, Ark server and Tor route", Icons.Default.SettingsEthernet) { navigate("Connections") }
                                        NavCard("Full encrypted backup", "Protect your keys and Ark recovery data", Icons.Default.Shield) { navigate("Backup") }
                                        NavCard("Emergency exit", "Recover Ark funds without the Ark server", Icons.Default.Security) { navigate("Emergency exit"); model.checkExit() }
                                        CardBlock("Appearance") { Choices(listOf("System", "Light", "Dark"), appearance) {
                                            appearance = it; preferences.edit().putString("mode", it).apply()
                                        } }
                                        Text("Paperclip Android · ${BuildConfig.VERSION_NAME}", color = colors.onSurfaceVariant)
                                    }
                                    "Connections" -> Connections(s, model)
                                    "Backup" -> Backup(s, model)
                                    "Emergency exit" -> EmergencyExit(s, model)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable private fun Brand() {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Image(painterResource(R.drawable.paperclip_logo), "Paperclip", Modifier.size(48.dp))
        Column { Text("PAPERCLIP", fontWeight = FontWeight.Bold, letterSpacing = 3.sp, fontSize = 21.sp)
            Text("POOL · XBT WALLET", fontSize = 10.sp, letterSpacing = 2.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}
@Composable private fun CardBlock(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(Modifier.fillMaxWidth(), border = BorderStroke(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = .09f)), shape = RoundedCornerShape(26.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                Box(Modifier.width(3.dp).height(15.dp).background(Orange, RoundedCornerShape(2.dp)))
                Text(title, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.SemiBold)
            }
            content()
        }
    }
}
@Composable private fun NavCard(title: String, subtitle: String, icon: androidx.compose.ui.graphics.vector.ImageVector, action: () -> Unit) {
    Card(onClick = action, shape = RoundedCornerShape(26.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Row(Modifier.fillMaxWidth().padding(22.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, Modifier.background(Orange.copy(alpha = .09f), RoundedCornerShape(12.dp)).padding(10.dp).size(22.dp), tint = MaterialTheme.colorScheme.primary)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) { Text(title, fontWeight = FontWeight.SemiBold); Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Icon(Icons.Default.ChevronRight, null)
        }
    }
}
@OptIn(ExperimentalLayoutApi::class)
@Composable private fun Choices(values: List<String>, selected: String, choose: (String) -> Unit) {
    FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        values.forEach { value -> FilterChip(selected = selected == value, onClick = { choose(value) }, label = { Text(value) }) }
    }
}
@Composable private fun Field(label: String, value: String, secret: Boolean = false, number: Boolean = false, change: (String) -> Unit) {
    OutlinedTextField(value, change, label = { Text(label) }, modifier = Modifier.fillMaxWidth(),
        visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = if (secret) KeyboardType.Password else if (number) KeyboardType.Number else KeyboardType.Text),
        shape = RoundedCornerShape(16.dp), singleLine = true)
}
@Composable private fun Dashboard(s: WalletState, model: WalletModel, navigate: (String) -> Unit) {
    var hidden by rememberSaveable { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Default.Circle, null, Modifier.size(8.dp), tint = if (s.connected) Color(0xff53b88c) else MaterialTheme.colorScheme.onSurfaceVariant)
        Text("  ${if (s.network == "xbt-mainnet") "XBT MAINNET" else "REGTEST"} · ${if (s.connected) "Connected" else "Offline"}", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium)
        IconButton(onClick = { hidden = !hidden }) { Icon(if (hidden) Icons.Default.VisibilityOff else Icons.Default.Visibility, "Toggle balance visibility") }
    }
    CardBlock("Your Keys. Your Bitcoin.") {
        Text(if (hidden) "••••••" else if (s.chain != null && s.ark != null) "${s.chain + s.ark} sats" else "— sats",
            style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold)
        Text(if (s.chain != null && s.ark != null) "On-chain + Ark" else "Connect and sync to see your total balance", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { navigate("Send") }, enabled = !s.busy, modifier = Modifier.weight(1f)) { Text("Send") }
            OutlinedButton(onClick = { navigate("Receive") }, enabled = !s.busy, modifier = Modifier.weight(1f)) { Text("Receive") }
        }
    }
    CardBlock("Balances") {
        BalanceRow("On-chain", if (hidden) "••••" else s.chain?.let { "$it sats" } ?: "Unavailable")
        HorizontalDivider(); BalanceRow("Ark", if (hidden) "••••" else s.ark?.let { "$it sats" } ?: "Connect to sync")
    }
    if (s.expiryHeight != null) CardBlock("Ark maintenance") {
        BalanceRow("Earliest expiry", "Block ${s.expiryHeight}")
        Text("Open and sync regularly. Refresh eligible funds before expiry, or use an emergency exit. Background refresh is not yet available on Android.", style = MaterialTheme.typography.bodySmall)
        OutlinedButton(onClick = model::refreshArk, enabled = s.connected && !s.busy, modifier = Modifier.fillMaxWidth()) { Text("Refresh eligible funds") }
    }
    if (!s.connected) NavCard("Connect your wallet", "Chain backend, Ark server and Tor route", Icons.Default.SettingsEthernet) { navigate("Connections") }
    else OutlinedButton(onClick = model::sync, enabled = !s.busy, modifier = Modifier.fillMaxWidth()) { Text("Sync wallet") }
    CardBlock("Recovery reminder") { Text("Save a fresh full backup after using Ark. Recovery words alone do not include your Ark exit data.") }
}
@Composable private fun BalanceRow(name: String, amount: String) { Row(Modifier.fillMaxWidth()) { Text(name, Modifier.weight(1f)); Text(amount, fontWeight = FontWeight.SemiBold) } }

@Composable private fun Setup(model: WalletModel, s: WalletState, scroll: ScrollState) {
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current
    var mode by remember { mutableStateOf("welcome") }
    LaunchedEffect(mode, s.phrase) { scroll.scrollTo(0) }
    var confirmation by remember(s.phrase) { mutableStateOf("") }
    val words = s.phrase.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
    BackHandler(mode != "welcome" && !s.busy) { mode = "welcome"; confirmation = "" }
    Brand()
    Text(if (mode == "verify") "Verify your seed" else if (words.isNotEmpty()) "Back up your wallet" else "Your XBT starts here",
        style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
    Text("On-chain · Lightning · Ark", color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (words.isNotEmpty()) {
        if (mode == "verify") CardBlock("Verify your seed") {
            Text("Enter all ${words.size} words in order from your written copy. Your phrase stays hidden during verification.")
            OutlinedTextField(confirmation, { confirmation = it }, modifier = Modifier.fillMaxWidth().testTag("seed-confirmation"),
                label = { Text("Recovery words") }, minLines = 4, shape = RoundedCornerShape(16.dp),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false))
            val matches = confirmation.trim().lowercase().split(Regex("\\s+")) == words
            Button(onClick = { focus.clearFocus(); keyboard?.hide(); model.create(s.phrase); confirmation = "" }, enabled = matches && !s.busy,
                modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp)) { Text("Verify and create wallet") }
            TextButton(onClick = { mode = "welcome"; confirmation = "" }) { Text("Show words again") }
        } else CardBlock("Write down these ${words.size} words") {
            Text("Keep these words offline and in order. Anyone with them can access your wallet.", style = MaterialTheme.typography.bodyMedium)
            Text("Read down the left column, then down the right.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            SeedWords(words)
            Button(onClick = { mode = "verify" }, enabled = !s.busy, modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp)) { Text("I wrote down every word") }
        }
    } else if (mode == "import") CardBlock("Import seed words") {
        var phrase by remember { mutableStateOf("") }
        OutlinedTextField(phrase, { phrase = it }, label = { Text("12 or 24 recovery words") }, modifier = Modifier.fillMaxWidth(), minLines = 4, shape = RoundedCornerShape(16.dp), keyboardOptions = KeyboardOptions(autoCorrectEnabled = false))
        Text("Seed-only recovery does not restore complete Ark recovery data. Use a full backup for an existing Ark wallet.", style = MaterialTheme.typography.bodySmall)
        Button(onClick = { model.create(phrase) }, enabled = phrase.isNotBlank() && !s.busy, modifier = Modifier.fillMaxWidth()) { Text("Import seed words") }
        TextButton(onClick = { mode = "welcome" }) { Text("Back") }
    } else if (mode == "backup") CardBlock("Restore a backup") {
        RestoreBackup(s.busy); TextButton(onClick = { mode = "welcome" }) { Text("Back") }
    } else {
        CardBlock("Mobile wallet") {
            Text("Create a wallet with keys stored securely on this device. We’ll guide you through backing up and verifying your seed.", style = MaterialTheme.typography.bodyMedium)
            Button(onClick = model::generate, enabled = !s.busy, modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp)) { Text(if (s.network == "xbt-mainnet") "Create a wallet" else "Create a test wallet") }
        }
        NavCard("Import seed words", "Restore a 12- or 24-word phrase", Icons.Default.Key) { mode = "import" }
        NavCard("Restore a backup", "Recover your encrypted wallet and Ark data", Icons.Default.Shield) { mode = "backup" }
    }
    Text(if (s.network == "xbt-mainnet") "XBT mainnet · Your keys stay on this device." else "Regtest · Test funds only.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    s.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
}

@Composable internal fun SeedWords(words: List<String>) {
    val rows = (words.size + 1) / 2
    Row(Modifier.fillMaxWidth().testTag("seed-words"), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        repeat(2) { column ->
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                for (index in column * rows until minOf((column + 1) * rows, words.size)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = "Word ${index + 1}, ${words[index]}" }) {
                        Text("${index + 1}", Modifier.width(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
                        Text(words[index], fontFamily = FontFamily.Monospace, fontSize = 15.sp, fontWeight = FontWeight.Medium, modifier = Modifier.testTag("seed-word-$index"))
                    }
                }
            }
        }
    }
}
@Composable private fun Send(s: WalletState, model: WalletModel) {
    val result = s.result
    if (result != null) {
        val status = PaymentStatus.from(result.optString("state"))
        CardBlock(status.title) {
            Icon(if (status == PaymentStatus.COMPLETE) Icons.Default.CheckCircle else if (status == PaymentStatus.NOT_SENT) Icons.Default.ErrorOutline else Icons.Default.Schedule,
                null, Modifier.size(60.dp), tint = if (status == PaymentStatus.COMPLETE) Color(0xff53b88c) else Orange)
            Text(status.detail)
            result.optString("txid").takeIf { it.isNotEmpty() }?.let { SelectionContainer { Text(it) } }
            result.optString("reason").takeIf { it.isNotEmpty() }?.let { Text(it) }
            OutlinedButton(onClick = model::checkPayment, enabled = !s.busy && s.connected) { Text("Check payment status") }
            if (status in listOf(PaymentStatus.COMPLETE, PaymentStatus.NOT_SENT)) {
                Button(onClick = model::dismissResult, enabled = !s.busy) { Text("Done") }
            }
        }
        return
    }
    val quote = s.review
    if (quote != null) {
        CardBlock("Review payment") {
            SelectionContainer { Text(quote.destination) }
            BalanceRow("Amount", "${quote.amount} sats"); BalanceRow("Fee", "${quote.fee} sats")
            HorizontalDivider(); BalanceRow("Total", "${quote.total} sats")
            Text("Quotes expire after 60 seconds. Confirm only if these details are correct.")
            Button(onClick = model::send, enabled = !s.busy, modifier = Modifier.fillMaxWidth()) { Text("Confirm and send") }
            TextButton(onClick = model::cancelReview, enabled = !s.busy) { Text("Cancel") }
        }
    } else {
        var destination by remember { mutableStateOf("") }; var amount by remember { mutableStateOf("") }; var source by rememberSaveable { mutableStateOf("Ark") }
        CardBlock("Send XBT") {
            Choices(listOf("Ark", "On-chain"), source) { source = it }
            Field("Address, invoice or offer", destination) { destination = it }
            Field("Amount in sats", amount, number = true) { amount = it }
            Text(if (source == "Ark") "Ark address, on-chain withdrawal, BOLT11 invoice or BOLT12 offer." else "Send from your on-chain balance.", style = MaterialTheme.typography.bodySmall)
            Button(onClick = { model.quote(destination, amount, source == "On-chain") }, enabled = !s.busy && s.connected,
                modifier = Modifier.fillMaxWidth()) { Text("Review payment") }
            if (!s.connected) Text("Connect your chain backend in Settings first.")
        }
    }
}
@Composable private fun Receive(s: WalletState, model: WalletModel) {
    var kind by rememberSaveable { mutableStateOf("On-chain") }; var amount by remember { mutableStateOf("") }
    CardBlock("Receive XBT") {
        Choices(listOf("On-chain", "Ark", "Lightning"), kind) { kind = it; model.clearReceive() }
        if (kind == "Lightning") Field("Amount in sats", amount, number = true) { amount = it }
        Button(onClick = { model.receive(kind, amount) }, enabled = !s.busy && (kind == "On-chain" || s.connected)) { Text(if (kind == "Lightning") "Create invoice" else "Create address") }
        if (s.address.isNotEmpty()) {
            val qr = remember(s.address) {
                val bits = QRCodeWriter().encode(s.address, BarcodeFormat.QR_CODE, 640, 640)
                Bitmap.createBitmap(640, 640, Bitmap.Config.ARGB_8888).apply {
                    val pixels = IntArray(640 * 640) { if (bits[it % 640, it / 640]) android.graphics.Color.BLACK else android.graphics.Color.WHITE }
                    setPixels(pixels, 0, 640, 0, 0, 640, 640)
                }.asImageBitmap()
            }
            Image(qr, "Receive QR code", Modifier.fillMaxWidth().aspectRatio(1f)); SelectionContainer { Text(s.address) }
            val context = LocalContext.current
            OutlinedButton(onClick = { (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Receive address", s.address)) }) { Text("Copy") }
        }
    }
}
@Composable private fun Lightning(navigate: (String) -> Unit) {
    CardBlock("Lightning through Ark") {
        Icon(Icons.Default.Bolt, null, Modifier.size(44.dp), tint = Orange)
        Text("Pay invoices and offers from your Ark balance.", style = MaterialTheme.typography.titleLarge)
        Text("BOLT11 and BOLT12 payments use the shared iPhone wallet engine. Review the fee before confirming.")
        Button(onClick = { navigate("Send") }) { Text("Pay with Ark") }
        OutlinedButton(onClick = { navigate("Receive") }) { Text("Receive a Lightning payment") }
    }
    CardBlock("Your Lightning node") { Text("CLN and LND remote-node connections are not yet available in this Android preview.") }
}
@Composable private fun Activity(s: WalletState, model: WalletModel) {
    Text("Activity", style = MaterialTheme.typography.headlineLarge)
    s.result?.let { result -> CardBlock(PaymentStatus.from(result.optString("state")).title) {
        Text(PaymentStatus.from(result.optString("state")).detail)
        OutlinedButton(onClick = model::checkPayment, enabled = s.connected && !s.busy) { Text("Check status") }
    } }
    if (s.activity.isEmpty()) CardBlock("No activity loaded") { Text(if (s.connected) "Sync to load your transactions." else "Connect and sync to see your on-chain and Ark activity.") }
    s.activity.forEach { CardBlock("Transaction") { SelectionContainer { Text(it) } } }
}
@Composable private fun Connections(s: WalletState, model: WalletModel) {
    var c by remember(s.connection) { mutableStateOf(s.connection) }
    CardBlock("Connection settings") {
        Text(if (s.network == "xbt-mainnet") "Paperclip mainnet endpoints are filled in for you. You can use your own compatible servers." else "Enter your regtest endpoints. The engine verifies the network before use.")
        Choices(listOf("electrum", "esplora", "rpc"), c.backend) { c = c.copy(backend = it) }
        Field("Chain endpoint", c.endpoint) { c = c.copy(endpoint = it) }; Field("Ark server", c.server) { c = c.copy(server = it) }
        if (c.backend == "rpc") { Field("RPC username", c.username) { c = c.copy(username = it) }; Field("RPC password", c.password, secret = true) { c = c.copy(password = it) } }
        if (c.backend == "electrum") Field("Certificate SHA256 (optional)", c.certificatePin) { c = c.copy(certificatePin = it) }
        Text("Connection privacy", fontWeight = FontWeight.SemiBold)
        Choices(listOf("Built-in Tor", "External Tor", "Direct"), if (c.proxy == "builtin") "Built-in Tor" else if (c.proxy.isEmpty()) "Direct" else "External Tor") {
            c = c.copy(proxy = when (it) { "Built-in Tor" -> "builtin"; "External Tor" -> "socks5h://127.0.0.1:9050"; else -> "" })
        }
        if (c.proxy.isNotEmpty() && c.proxy != "builtin") Field("Tor SOCKS proxy", c.proxy) { c = c.copy(proxy = it) }
        Text(if (c.proxy.isEmpty()) "Direct connections reveal your IP address to the server." else "Remote server traffic and DNS use Tor. If Tor is unavailable, the connection fails without falling back to direct access. Localhost services stay local; select Direct for a LAN node.", style = MaterialTheme.typography.bodySmall)
        if (s.busy && c.proxy == "builtin") Text("Connecting through Tor… First startup can take a few minutes.")
        Button(onClick = { model.connect(c) }, enabled = !s.busy, modifier = Modifier.fillMaxWidth()) { Text("Save and connect") }
    }
}
@Composable private fun Backup(s: WalletState, model: WalletModel) {
    val activity = LocalContext.current as MainActivity
    var keySaved by remember { mutableStateOf(false) }
    CardBlock("Complete recovery backup") {
        Text("Includes keys, the complete wallet database and Ark recovery data. Save a fresh backup after using Ark. A seed phrase alone is not enough for offline Ark recovery.")
        Button(onClick = { keySaved = false; model.prepareBackup() }, enabled = !s.busy) { Text("Prepare encrypted backup") }
        if (s.recoveryKey.isNotEmpty()) {
            Text("Recovery key — store separately", fontWeight = FontWeight.SemiBold)
            SelectionContainer { Text(s.recoveryKey) }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(keySaved, { keySaved = it }); Text("I stored the recovery key separately")
            }
            Button(onClick = activity::exportBackup, enabled = keySaved && !s.busy) { Text("Save backup file") }
            if (s.backupSaved) Text("Backup file saved. Keep the recovery key separately.")
        }
    }
}
@Composable private fun RestoreBackup(busy: Boolean) {
    var key by remember { mutableStateOf("") }
    val activity = LocalContext.current as MainActivity
    Field("Full-backup recovery key", key, secret = true) { key = it }
    OutlinedButton(onClick = { activity.restoreBackup(key); key = "" }, enabled = !busy && key.isNotBlank()) { Text("Restore full backup") }
}

@Composable private fun EmergencyExit(s: WalletState, model: WalletModel) {
    var confirmed by remember { mutableStateOf(false) }
    var destination by remember { mutableStateOf("") }
    CardBlock("Recover on-chain") {
        Text("An emergency exit uses your saved Ark recovery data and the chain backend. It does not require the Ark server to be online.")
        Text("Exits incur on-chain fees and take time to become claimable. Keep a full backup and enough on-chain funds for fees.", style = MaterialTheme.typography.bodySmall)
        s.exitStatus?.let {
            BalanceRow("Pending exit", if (it.optBoolean("pending")) "Yes" else "No")
            if (!it.isNull("claimable_height")) BalanceRow("Claimable at height", it.optString("claimable_height"))
            BalanceRow("Claimable outputs", it.optInt("claimable_count").toString())
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(confirmed, { confirmed = it }); Text("I understand the fees and waiting period")
        }
        Button(onClick = model::startExit, enabled = confirmed && s.connected && !s.busy, modifier = Modifier.fillMaxWidth()) { Text("Start emergency exit") }
        OutlinedButton(onClick = model::progressExit, enabled = s.connected && !s.busy, modifier = Modifier.fillMaxWidth()) { Text("Continue exit and broadcast") }
        TextButton(onClick = model::checkExit, enabled = !s.busy) { Text("Check exit status") }
        if ((s.exitStatus?.optInt("claimable_count") ?: 0) > 0) {
            Field("On-chain destination", destination) { destination = it }
            Text("Claiming sends the matured outputs to this address, less the on-chain fee. Verify the address before confirming.", style = MaterialTheme.typography.bodySmall)
            Button(onClick = { confirmed = false; model.claimExit(destination) }, enabled = confirmed && s.connected && !s.busy && destination.isNotBlank() && s.result == null) { Text("Confirm and claim outputs") }
        }
        s.result?.let { Text(PaymentStatus.from(it.optString("state")).title) }
    }
}
