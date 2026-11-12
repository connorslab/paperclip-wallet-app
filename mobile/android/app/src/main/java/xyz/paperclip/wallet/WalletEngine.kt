package xyz.paperclip.wallet

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.util.Base64
import java.util.UUID

internal object NativeBridge {
    init { System.loadLibrary("paperclip_android") }
    external fun call(request: ByteArray, seed: ByteArray): ByteArray
}

class WalletEngine(context: Context) {
    private val vault = SecureStore(context)
    private val root = File(context.noBackupFilesDir, "wallets").apply { mkdirs() }
    private val mutex = Mutex()
    private var record: JSONObject? = null
    private var opened = false
    private var connected = false
    private fun invoke(op: String, fields: JSONObject = JSONObject(), seed: ByteArray? = null): JSONObject {
        val key = seed ?: record?.getString("seed")?.let { Base64.getDecoder().decode(it) } ?: ByteArray(64)
        try {
            val response = NativeBridge.call(fields.put("op", op).toString().toByteArray(Charsets.UTF_8), key)
            val result = try { JSONObject(String(response, Charsets.UTF_8)) } finally { response.fill(0) }
            if (result.has("error")) error(result.getString("error"))
            return result.getJSONObject("ok")
        } finally { key.fill(0) }
    }
    private suspend fun <T> serial(work: () -> T): T = withContext(Dispatchers.IO) { mutex.withLock { work() } }
    suspend fun hasWallet() = serial { vault.read("wallet")?.also { it.fill(0) } != null }
    suspend fun phrase() = serial { invoke("seed_generate").getString("phrase") }
    suspend fun create(phrase: String) = serial {
        check(vault.read("wallet") == null) { "A wallet already exists" }
        val derived = invoke("seed_derive", JSONObject().put("phrase", phrase))
        val id = UUID.randomUUID().toString()
        val next = JSONObject().put("seed", derived.getString("seed")).put("phrase", phrase)
            .put("network", "xbt-regtest").put("id", id).put("provisioning", true)
        // Persist identity first so interrupted provisioning reopens the same wallet.
        vault.write("wallet", next.toString().toByteArray())
        record = next
        openStored()
    }
    private fun openStored() {
        if (opened) return
        if (record == null) {
            val bytes = vault.read("wallet") ?: error("Create or restore a wallet first")
            record = try { JSONObject(String(bytes, Charsets.UTF_8)) } finally { bytes.fill(0) }
        }
        val r = record!!
        check(r.getString("network") == "xbt-regtest") { "Mainnet remains disabled until Android recovery and device validation are complete" }
        val id = UUID.fromString(r.getString("id")).toString()
        val directory = File(root, id)
        val exists = File(directory, "db.sqlite").exists()
        check(exists || r.optBoolean("provisioning")) { "Wallet database is missing. Restore a full backup; do not create a replacement." }
        invoke(if (exists) "open" else "create",
            JSONObject().put("directory", directory.absolutePath).put("network", r.getString("network")))
        if (r.optBoolean("provisioning")) {
            r.put("provisioning", false)
            vault.write("wallet", r.toString().toByteArray())
        }
        opened = true
    }
    suspend fun open() = serial { openStored(); invoke("overview_onchain") }
    suspend fun connection(): Connection = serial {
        vault.read("connection")?.let { bytes ->
            try { Connection.from(JSONObject(String(bytes, Charsets.UTF_8))) } finally { bytes.fill(0) }
        } ?: Connection()
    }
    suspend fun connect(settings: Connection) = serial {
        settings.validate(); openStored(); connected = false
        val config = invoke("config_template").put("server_address", settings.server)
            .put("electrum_address", if (settings.backend == "electrum") settings.endpoint else JSONObject.NULL)
            .put("esplora_address", if (settings.backend == "esplora") settings.endpoint else JSONObject.NULL)
            .put("bitcoind_address", if (settings.backend == "rpc") settings.endpoint else JSONObject.NULL)
            .put("bitcoind_user", settings.username).put("bitcoind_pass", settings.password)
            .put("electrum_certificate_sha256", settings.certificatePin.ifEmpty { null } ?: JSONObject.NULL)
            .put("socks5_proxy", settings.proxy.ifEmpty { null } ?: JSONObject.NULL)
            .put("user_agent", "paperclip-android/0.1.0-dev")
        invoke("connect", JSONObject().put("config", config))
        invoke("chain_health") // Never equate a constructed client with a healthy backend.
        vault.write("connection", settings.json().toString().toByteArray())
        connected = true
    }
    suspend fun call(op: String, fields: JSONObject = JSONObject()): JSONObject = serial {
        openStored()
        if (op !in listOf("overview_onchain", "address_onchain", "addresses_onchain", "exit_status")) check(connected) { "Connect your regtest node in Settings first" }
        invoke(op, fields)
    }
    suspend fun backup(key: String): ByteArray = serial {
        openStored()
        val snapshot = invoke("backup")
        val r = record!!
        val archive = JSONObject().put("version", 1).put("network", r.getString("network"))
            .put("walletID", r.getString("id")).put("createdAt", System.currentTimeMillis() / 1000.0 - 978307200)
            .put("seed", r.getString("seed")).put("seedPhrase", r.optString("phrase").ifEmpty { null } ?: JSONObject.NULL)
            .put("recoveryState", snapshot.getString("database"))
        val plain = archive.toString().toByteArray()
        try { BackupCodec.seal(plain, key) } finally { plain.fill(0) }
    }
    suspend fun restore(bytes: ByteArray, key: String) = serial {
        check(vault.read("wallet") == null) { "Restore requires an empty app; existing wallets are never overwritten" }
        val plain = BackupCodec.open(bytes, key)
        val archive = try { JSONObject(String(plain, Charsets.UTF_8)) } finally { plain.fill(0) }
        require(archive.getInt("version") == 1 && archive.getString("network") == "xbt-regtest") { "This preview accepts regtest backups only" }
        val seed = Base64.getDecoder().decode(archive.getString("seed"))
        require(seed.size == 64) { "Invalid recovery seed" }
        val phrase = if (archive.isNull("seedPhrase")) "" else archive.optString("seedPhrase")
        if (phrase.isNotEmpty()) {
            val derived = invoke("seed_derive", JSONObject().put("phrase", phrase))
            require(derived.getString("seed") == archive.getString("seed")) { "Backup words do not match its seed" }
        }
        val id = UUID.randomUUID().toString()
        invoke("restore", JSONObject().put("network", "xbt-regtest").put("directory", File(root, id).absolutePath)
            .put("database", archive.getString("recoveryState")), seed)
        val next = JSONObject().put("network", "xbt-regtest").put("id", id)
            .put("seed", archive.getString("seed")).put("phrase", phrase)
        vault.write("wallet", next.toString().toByteArray()); record = next; openStored()
    }
    suspend fun savePending(result: JSONObject) = serial { vault.write("pending", result.toString().toByteArray()) }
    suspend fun pending() = serial { vault.read("pending")?.let { JSONObject(String(it, Charsets.UTF_8)) } }
    suspend fun close() = serial {
        if (opened) invoke("close")
        opened = false; connected = false; record = null
    }
}
