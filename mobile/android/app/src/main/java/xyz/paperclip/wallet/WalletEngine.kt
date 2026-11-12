package xyz.paperclip.wallet

import android.content.Context
import java.io.File
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

internal object NativeBridge {
	init {
		System.loadLibrary("paperclip_android")
	}

	external fun cancelSync(id: Long)

	external fun call(request: ByteArray, seed: ByteArray): ByteArray
}

class WalletEngine private constructor(context: Context) {
	private val appContext = context.applicationContext

	companion object {
		@Volatile private var instance: WalletEngine? = null

		fun shared(context: Context): WalletEngine =
			instance
				?: synchronized(this) {
					instance ?: WalletEngine(context.applicationContext).also { instance = it }
				}
	}

	private val vault = SecureStore(context)
	private val root = File(context.noBackupFilesDir, "wallets").apply { mkdirs() }
	private val mutex = Mutex()
	private var record: JSONObject? = null
	private var opened = false
	private var connected = false
	@Volatile private var activeSync = 0L
	private val syncSequence = java.util.concurrent.atomic.AtomicLong(0)

	fun cancelSync() {
		activeSync.takeIf { it > 0 }?.let(NativeBridge::cancelSync)
	}

	private fun invoke(
		op: String,
		fields: JSONObject = JSONObject(),
		seed: ByteArray? = null,
	): JSONObject {
		val key =
			seed
				?: record
					?.optString("seed")
					?.takeIf { it.isNotEmpty() }
					?.let { Base64.getDecoder().decode(it) }
				?: ByteArray(64)
		try {
			val response =
				NativeBridge.call(fields.put("op", op).toString().toByteArray(Charsets.UTF_8), key)
			val result =
				try {
					JSONObject(String(response, Charsets.UTF_8))
				} finally {
					response.fill(0)
				}
			if (result.has("error")) error(result.getString("error"))
			return result.getJSONObject("ok")
		} finally {
			key.fill(0)
		}
	}

	private suspend fun <T> serial(work: () -> T): T =
		withContext(Dispatchers.IO) { mutex.withLock { work() } }

	private fun readJSON(name: String): JSONObject? =
		vault.read(name)?.let { bytes ->
			try {
				JSONObject(String(bytes, Charsets.UTF_8))
			} finally {
				bytes.fill(0)
			}
		}

	private fun registry(): WalletRegistry {
		val index =
			readJSON("wallet-registry")?.let(::WalletRegistry)
				?: WalletRegistry.migrate(readJSON("wallet")).also { saveRegistry(it) }
		readJSON("wallet-removal")?.let { finishRemoval(index, it.getString("id")) }
		return index
	}

	private fun finishRemoval(index: WalletRegistry, id: String) {
		require(UUID.fromString(id).toString() == id)
		val directory = File(root, id)
		require(directory.canonicalFile.parentFile == root.canonicalFile)
		check(!directory.exists() || directory.deleteRecursively()) {
			"Could not finish removing local wallet data"
		}
		val pending = pendingRecords()
		pending.remove(id)
		vault.write("wallet-pending", pending.toString().toByteArray())
		if (readJSON("wallet")?.optString("id") == id) {
			vault.delete("wallet")
			vault.delete("pending")
		}
		if (index.entries().any { it.getString("id") == id }) index.remove(id)
		saveRegistry(index)
		ExpiryReminders.forget(appContext, id)
		PaymentAlerts(appContext).forget(id)
		vault.delete("wallet-removal")
	}

	suspend fun removeWallet(
		id: String,
		expectedName: String,
		confirmation: String,
		backupAcknowledged: Boolean,
	) = serial {
		val index = registry()
		val selected =
			index.entries().firstOrNull { it.getString("id") == id }
				?: error("Wallet no longer exists")
		require(
			selected.optString("name", "Wallet") == expectedName &&
				backupAcknowledged &&
				confirmation == "REMOVE $expectedName",
		) {
			"Verify your backup and type the exact removal confirmation"
		}
		if (opened) invoke("close")
		opened = false
		connected = false
		record = null
		vault.write("wallet-removal", JSONObject().put("id", id).toString().toByteArray())
		finishRemoval(index, id)
	}

	private fun saveRegistry(r: WalletRegistry) {
		val bytes = r.json().toString().toByteArray()
		try {
			vault.write("wallet-registry", bytes)
		} finally {
			bytes.fill(0)
		}
	}

	private fun saveRecord(r: JSONObject) {
		val index = registry()
		index.put(r)
		saveRegistry(index)
	}

	suspend fun profiles() = serial {
		registry().entries().map {
			WalletProfile(
				it.getString("id"),
				it.optString("name", "Wallet"),
				it.optString("kind", "hot"),
				it.getString("network"),
			)
		}
	}

	suspend fun activeID() = serial { registry().selected()?.getString("id") }

	suspend fun select(id: String) = serial {
		val index = registry()
		index.select(id)
		if (opened) invoke("close")
		opened = false
		connected = false
		record = null
		saveRegistry(index)
		openStored()
		invoke("overview_onchain")
	}

	suspend fun rename(id: String, name: String) = serial {
		val index = registry()
		index.rename(id, name)
		saveRegistry(index)
	}

	suspend fun hasWallet() = serial { registry().selected() != null }

	suspend fun phrase() = serial { invoke("seed_generate").getString("phrase") }

	suspend fun phraseFromEntropy(entropy: ByteArray) = serial {
		try {
			invoke(
					"seed_from_entropy",
					JSONObject().put("entropy", Base64.getEncoder().encodeToString(entropy)),
				)
				.getString("phrase")
		} finally {
			entropy.fill(0)
		}
	}

	suspend fun network(): String? = serial { registry().selected()?.getString("network") }

	suspend fun create(phrase: String, network: String = "xbt-regtest", name: String = "Wallet") =
		serial {
			require(network in listOf("xbt-mainnet", "xbt-regtest")) { "Unsupported network" }
			require(name.isNotBlank() && name.length <= 80)
			val derived = invoke("seed_derive", JSONObject().put("phrase", phrase))
			val index = registry()
			check(
				index.entries().none {
					it.optString("seed") == derived.getString("seed") &&
						it.getString("network") == network
				},
			) {
				"This wallet is already imported"
			}
			if (opened) invoke("close")
			opened = false
			connected = false
			val id = UUID.randomUUID().toString()
			val next =
				JSONObject()
					.put("seed", derived.getString("seed"))
					.put("phrase", phrase)
					.put("network", network)
					.put("id", id)
					.put("name", name)
					.put("kind", "hot")
					.put("provisioning", true)
			saveRecord(next)
			record = next
			openStored()
		}

	suspend fun importPublic(
		key: String,
		origin: String,
		script: String,
		hardware: Boolean,
		network: String,
		name: String,
	) = serial {
		require(name.isNotBlank() && name.length <= 80)
		val descriptor =
			invoke(
				"validate_public_wallet",
				JSONObject()
					.put("public_key", key)
					.put("origin", origin)
					.put("script", script)
					.put("hardware", hardware)
					.put("network", network),
			)
		val receive = descriptor.getString("receive")
		check(
			registry().entries().none {
				it.optString("descriptor") == receive && it.getString("network") == network
			},
		) {
			"This public wallet is already imported"
		}
		if (opened) invoke("close")
		opened = false
		connected = false
		val next =
			JSONObject()
				.put("id", UUID.randomUUID().toString())
				.put("network", network)
				.put("kind", if (hardware) "hardware" else "watch")
				.put("descriptor", receive)
				.put("name", name)
				.put("provisioning", true)
		saveRecord(next)
		record = next
		openStored()
	}

	suspend fun previewPublic(
		key: String,
		origin: String,
		script: String,
		hardware: Boolean,
		network: String,
	) = serial {
		invoke(
			"validate_public_wallet",
			JSONObject()
				.put("public_key", key)
				.put("origin", origin)
				.put("script", script)
				.put("hardware", hardware)
				.put("network", network),
		)
	}

	suspend fun exportPublic(id: String) = serial {
		val profile = registry().entries().first { it.getString("id") == id }
		require(profile.optString("kind") in listOf("hardware", "watch"))
		JSONObject()
			.put("name", profile.optString("name"))
			.put("network", profile.getString("network"))
			.put("kind", profile.getString("kind"))
			.put("descriptor", profile.getString("descriptor"))
	}

	private fun openStored() {
		if (opened) return
		if (record == null) {
			record = registry().selected() ?: error("Create or restore a wallet first")
		}
		val r = record!!
		check(r.getString("network") in listOf("xbt-mainnet", "xbt-regtest")) {
			"Unsupported wallet network"
		}
		val id = UUID.fromString(r.getString("id")).toString()
		val directory = File(root, id)
		val exists = File(directory, "db.sqlite").exists()
		check(exists || r.optBoolean("provisioning")) {
			"Wallet database is missing. Restore a full backup; do not create a replacement."
		}
		invoke(
			if (exists) "open" else "create",
			JSONObject()
				.put("directory", directory.absolutePath)
				.put("network", r.getString("network"))
				.put("kind", r.optString("kind", "hot"))
				.put("descriptor", r.optString("descriptor")),
		)
		if (r.optBoolean("provisioning")) {
			r.put("provisioning", false)
			saveRecord(r)
		}
		opened = true
	}

	suspend fun open() = serial {
		openStored()
		invoke("overview_onchain")
	}

	suspend fun connection(): Connection = serial {
		registry().selected()?.optJSONObject("connection")?.let {
			return@serial Connection.from(it)
		}
		vault.read("connection")?.let { bytes ->
			try {
				Connection.from(JSONObject(String(bytes, Charsets.UTF_8)))
			} finally {
				bytes.fill(0)
			}
		} ?: Connection()
	}

	suspend fun connect(settings: Connection) {
		settings.validate()
		serial { connected = false }
		val route =
			if (settings.proxy == "builtin") EmbeddedTor.proxy(appContext) else settings.proxy
		val arkRoute =
			settings.arkRpc?.let {
				if (it.proxy == "builtin") EmbeddedTor.proxy(appContext) else it.proxy
			}
		serial {
			settings.validate()
			openStored()
			connected = false
			val config =
				invoke("config_template")
					.put("server_address", settings.server)
					.put(
						"electrum_address",
						if (settings.backend == "electrum") settings.endpoint else JSONObject.NULL,
					)
					.put(
						"esplora_address",
						if (settings.backend == "esplora") settings.endpoint else JSONObject.NULL,
					)
					.put(
						"bitcoind_address",
						if (settings.backend == "rpc") settings.endpoint else JSONObject.NULL,
					)
					.put("bitcoind_user", settings.username)
					.put("bitcoind_pass", settings.password)
					.put(
						"electrum_certificate_sha256",
						settings.certificatePin.ifEmpty { null } ?: JSONObject.NULL,
					)
					.put("socks5_proxy", route.ifEmpty { null } ?: JSONObject.NULL)
					.put("user_agent", "paperclip-android/${BuildConfig.VERSION_NAME}")
			val request = JSONObject().put("config", config)
			settings.arkRpc
				?.takeIf { record!!.optString("kind", "hot") == "hot" }
				?.let { rpc ->
					val arkConfig =
						JSONObject(config.toString())
							.put("electrum_address", JSONObject.NULL)
							.put("esplora_address", JSONObject.NULL)
							.put("bitcoind_address", rpc.endpoint)
							.put("bitcoind_user", rpc.username)
							.put("bitcoind_pass", rpc.password)
							.put("electrum_certificate_sha256", JSONObject.NULL)
							.put(
								"socks5_proxy",
								arkRoute?.takeIf { it.isNotEmpty() } ?: JSONObject.NULL,
							)
					request.put("ark_config", arkConfig)
				}
			invoke("connect", request)
			invoke("chain_health") // Never equate a constructed client with a healthy backend.
			vault.write("connection", settings.json().toString().toByteArray())
			record?.let {
				it.put("connection", settings.json())
				saveRecord(it)
			}
			connected = true
			if (WalletMaintenance.foreground && record!!.optString("kind", "hot") == "hot")
				invoke("receive_listen", JSONObject().put("enabled", true))
		}
	}

	suspend fun prepareHardwareBoard(sourceID: String, amount: Long): JSONObject {
		val source = serial {
			openStored()
			check(connected && record!!.optString("kind", "hot") == "hot")
			val r = registry().entries().first { it.getString("id") == sourceID }
			require(
				r.getString("kind") == "hardware" &&
					r.getString("network") == record!!.getString("network"),
			)
			JSONObject(r.toString()).put("target_id", record!!.getString("id"))
		}
		val settings = source.optJSONObject("connection")?.let(Connection::from) ?: Connection()
		settings.validate()
		val route =
			if (settings.proxy == "builtin") EmbeddedTor.proxy(appContext) else settings.proxy
		return serial {
			openStored()
			check(connected && record!!.getString("id") == source.getString("target_id"))
			val current = registry().entries().first { it.getString("id") == sourceID }
			require(current.getString("descriptor") == source.getString("descriptor"))
			val config =
				invoke("config_template")
					.put("server_address", settings.server)
					.put(
						"electrum_address",
						if (settings.backend == "electrum") settings.endpoint else JSONObject.NULL,
					)
					.put(
						"esplora_address",
						if (settings.backend == "esplora") settings.endpoint else JSONObject.NULL,
					)
					.put(
						"bitcoind_address",
						if (settings.backend == "rpc") settings.endpoint else JSONObject.NULL,
					)
					.put("bitcoind_user", settings.username)
					.put("bitcoind_pass", settings.password)
					.put(
						"electrum_certificate_sha256",
						settings.certificatePin.ifEmpty { null } ?: JSONObject.NULL,
					)
					.put("socks5_proxy", route.ifEmpty { null } ?: JSONObject.NULL)
			val funding =
				JSONObject()
					.put("directory", File(root, UUID.fromString(sourceID).toString()).absolutePath)
					.put("descriptor", source.getString("descriptor"))
					.put("identity", Base64.getEncoder().encodeToString(ByteArray(64)))
					.put("config", config)
			invoke(
				"ark_hardware_prepare",
				JSONObject().put("amount_sat", amount).put("source", funding),
			)
		}
	}

	suspend fun call(op: String, fields: JSONObject = JSONObject()): JSONObject = serial {
		openStored()
		if (
			op !in
				listOf(
					"overview_onchain",
					"address_onchain",
					"addresses_onchain",
					"exit_status",
					"sign_message_onchain",
					"select_onchain_account",
				)
		)
			check(connected) { "Connect your chain backend in Settings first" }
		if (op == "sync_onchain") {
			val id = syncSequence.incrementAndGet()
			activeSync = id
			try {
				invoke(op, fields.put("sync_id", id))
			} finally {
				activeSync = 0
			}
		} else invoke(op, fields)
	}

	suspend fun callForWallet(
		id: String,
		op: String,
		fields: JSONObject = JSONObject(),
	): JSONObject = serial {
		openStored()
		check(record!!.getString("id") == id) {
			"Active wallet changed. Reopen this workflow in the original wallet."
		}
		require(op.startsWith("coinjoin_"))
		if (op !in setOf("coinjoin_status", "coinjoin_address"))
			check(connected) { "Connect the chain backend first" }
		invoke(op, fields)
	}

	suspend fun backup(key: String): ByteArray = serial {
		openStored()
		val snapshot = invoke("backup")
		val r = record!!
		val archive =
			JSONObject()
				.put("version", 1)
				.put("network", r.getString("network"))
				.put("walletID", r.getString("id"))
				.put("createdAt", System.currentTimeMillis() / 1000.0 - 978307200)
				.put("seed", r.getString("seed"))
				.put("seedPhrase", r.optString("phrase").ifEmpty { null } ?: JSONObject.NULL)
				.put("recoveryState", snapshot.getString("database"))
		val plain = archive.toString().toByteArray()
		try {
			BackupCodec.seal(plain, key)
		} finally {
			plain.fill(0)
		}
	}

	suspend fun restore(bytes: ByteArray, key: String, testOnly: Boolean = false) = serial {
		if (opened) invoke("close")
		opened = false
		connected = false
		record = null
		val plain = BackupCodec.open(bytes, key)
		val archive =
			try {
				JSONObject(String(plain, Charsets.UTF_8))
			} finally {
				plain.fill(0)
			}
		require(
			archive.getInt("version") == 1 &&
				archive.getString("network") in listOf("xbt-mainnet", "xbt-regtest"),
		) {
			"Unsupported backup network or version"
		}
		val network = archive.getString("network")
		check(
			registry().entries().none {
				it.optString("seed") == archive.getString("seed") &&
					it.getString("network") == network
			},
		) {
			"This wallet is already present. Existing wallets are never overwritten by restore."
		}
		require(!testOnly || network == "xbt-regtest") {
			"Screenshot mode cannot import a mainnet wallet"
		}
		val seed = Base64.getDecoder().decode(archive.getString("seed"))
		require(seed.size == 64) { "Invalid recovery seed" }
		val phrase = if (archive.isNull("seedPhrase")) "" else archive.optString("seedPhrase")
		if (phrase.isNotEmpty()) {
			val derived = invoke("seed_derive", JSONObject().put("phrase", phrase))
			require(derived.getString("seed") == archive.getString("seed")) {
				"Backup words do not match its seed"
			}
		}
		val id = UUID.randomUUID().toString()
		invoke(
			"restore",
			JSONObject()
				.put("network", network)
				.put("directory", File(root, id).absolutePath)
				.put("database", archive.getString("recoveryState")),
			seed,
		)
		val next =
			JSONObject()
				.put("network", network)
				.put("id", id)
				.put("seed", archive.getString("seed"))
				.put("phrase", phrase)
		saveRecord(next)
		record = next
		openStored()
	}

	private fun pendingRecords(): JSONObject {
		readJSON("wallet-pending")?.let {
			return it
		}
		val all = JSONObject()
		val old = readJSON("wallet")
		val legacy = readJSON("pending")
		if (old != null && legacy != null) all.put(old.getString("id"), legacy)
		vault.write("wallet-pending", all.toString().toByteArray())
		return all
	}

	suspend fun savePending(result: JSONObject) = serial {
		val all = pendingRecords()
		val id = registry().selected()?.getString("id") ?: error("No active wallet")
		all.put(id, result)
		vault.write("wallet-pending", all.toString().toByteArray())
	}

	suspend fun pending() = serial {
		val id = registry().selected()?.getString("id") ?: return@serial null
		pendingRecords().optJSONObject(id)
	}

	suspend fun close() = serial {
		if (opened) invoke("close")
		opened = false
		connected = false
		record = null
	}
}
