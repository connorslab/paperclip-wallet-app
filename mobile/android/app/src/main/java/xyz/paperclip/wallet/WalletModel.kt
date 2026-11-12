package xyz.paperclip.wallet

import android.app.Application
import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

data class WalletState(
	val profiles: List<WalletProfile> = emptyList(),
	val activeID: String = "",
	val toolsResult: JSONObject? = null,
	val loaded: Boolean = false,
	val hasWallet: Boolean = false,
	val busy: Boolean = false,
	val error: String? = null,
	val phrase: String = "",
	val chain: Long? = null,
	val ark: Long? = null,
	val reviewIssue: JSONObject? = null,
	val activityRecords: List<WalletActivity> = emptyList(),
	val connected: Boolean = false,
	val address: String = "",
	val review: PaymentReview? = null,
	val result: JSONObject? = null,
	val activity: List<String> = emptyList(),
	val connection: Connection = Connection(),
	val recoveryKey: String = "",
	val backup: ByteArray? = null,
	val backupSaved: Boolean = false,
	val exitStatus: JSONObject? = null,
	val expiryHeight: Long? = null,
	val network: String = "xbt-mainnet",
)

class WalletModel(app: Application) : AndroidViewModel(app) {
	private val engine = WalletEngine.shared(app)
	private val mutable = MutableStateFlow(WalletState())
	val state = mutable.asStateFlow()
	private var testOnly = false
	private var maintenance: kotlinx.coroutines.Job? = null

	private fun change(f: (WalletState) -> WalletState) {
		mutable.value = f(mutable.value)
	}

	private var generation = 0L

	private fun job(work: suspend () -> Unit) {
		if (mutable.value.busy) return
		change { it.copy(busy = true, error = null) }
		val ticket = generation
		viewModelScope.launch {
			try {
				PaymentGate.run {
					if (generation != ticket) throw kotlinx.coroutines.CancellationException()
					work()
				}
			} catch (e: kotlinx.coroutines.CancellationException) {
				throw e
			} catch (e: Exception) {
				change { it.copy(error = e.message ?: "Wallet operation failed") }
			} finally {
				change { it.copy(busy = false, loaded = true) }
			}
		}
	}

	// Called only after device authentication, never from initial composition.
	fun load(screenshots: Boolean = false) = job {
		testOnly = screenshots
		val network = engine.network() ?: if (testOnly) "xbt-regtest" else "xbt-mainnet"
		check(!testOnly || network == "xbt-regtest") {
			"Screenshot mode cannot open a mainnet wallet"
		}
		val present = engine.hasWallet()
		val profiles = engine.profiles()
		val id = engine.activeID() ?: ""
		val connection = engine.connection()
		change {
			it.copy(
				hasWallet = present,
				connection = connection,
				network = network,
				profiles = profiles,
				activeID = id,
			)
		}
		if (present) {
			val chain = engine.open().getLong("total_sat")
			val pending = engine.pending()
			change { it.copy(chain = chain, result = pending) }
		}
	}

	fun generate() = job {
		val phrase = engine.phrase()
		change { it.copy(phrase = phrase) }
	}

	internal fun generateFromEntropy(entropy: ByteArray) {
		if (mutable.value.busy) {
			entropy.fill(0)
			return
		}
		job {
			try {
				val phrase = engine.phraseFromEntropy(entropy)
				change { it.copy(phrase = phrase) }
			} finally {
				entropy.fill(0)
			}
		}
	}

	fun clearPhrase() {
		change { it.copy(phrase = "") }
	}

	fun removeWallet(profile: WalletProfile, confirmation: String, backupAcknowledged: Boolean) =
		job {
			clearBackup()
			engine.removeWallet(profile.id, profile.name, confirmation, backupAcknowledged)
			val profiles = engine.profiles()
			val id = engine.activeID() ?: ""
			val network = engine.network() ?: mutable.value.network
			val chain = if (id.isEmpty()) null else engine.open().getLong("total_sat")
			change {
				it.copy(
					profiles = profiles,
					activeID = id,
					hasWallet = profiles.isNotEmpty(),
					network = network,
					chain = chain,
					ark = null,
					connected = false,
					review = null,
					result = null,
					address = "",
					activity = emptyList(),
					activityRecords = emptyList(),
					toolsResult = null,
					phrase = "",
				)
			}
		}

	fun create(phrase: String) = job {
		check(!testOnly || mutable.value.network == "xbt-regtest")
		engine.create(phrase.trim(), mutable.value.network)
		val profiles = engine.profiles()
		val id = engine.activeID() ?: ""
		change {
			it.copy(
				hasWallet = true,
				phrase = "",
				chain = 0,
				ark = null,
				profiles = profiles,
				activeID = id,
			)
		}
	}

	fun selectWallet(id: String) = job {
		clearBackup()
		val overview = engine.select(id)
		val pending = engine.pending()
		val network = engine.network() ?: error("Missing wallet network")
		val connection = engine.connection()
		change {
			it.copy(
				activeID = id,
				network = network,
				chain = overview.getLong("total_sat"),
				ark = null,
				connected = false,
				connection = connection,
				review = null,
				result = pending,
				address = "",
				activity = emptyList(),
				activityRecords = emptyList(),
				toolsResult = null,
			)
		}
	}

	fun renameWallet(id: String, name: String) = job {
		engine.rename(id, name)
		val profiles = engine.profiles()
		change { it.copy(profiles = profiles) }
	}

	fun addWallet(phrase: String, name: String) = job {
		clearBackup()
		engine.create(phrase.trim(), mutable.value.network, name)
		val profiles = engine.profiles()
		val id = engine.activeID() ?: ""
		change {
			it.copy(
				profiles = profiles,
				activeID = id,
				hasWallet = true,
				phrase = "",
				chain = 0,
				ark = null,
				connected = false,
				review = null,
				result = null,
				activity = emptyList(),
				activityRecords = emptyList(),
				toolsResult = null,
			)
		}
	}

	fun importPublic(key: String, origin: String, script: String, hardware: Boolean, name: String) =
		job {
			clearBackup()
			engine.importPublic(
				key.trim(),
				origin.trim(),
				script,
				hardware,
				mutable.value.network,
				name,
			)
			val profiles = engine.profiles()
			val id = engine.activeID() ?: ""
			change {
				it.copy(
					profiles = profiles,
					activeID = id,
					hasWallet = true,
					chain = 0,
					ark = null,
					connected = false,
					review = null,
					result = null,
					activity = emptyList(),
					activityRecords = emptyList(),
					toolsResult = null,
				)
			}
		}

	fun previewPublic(key: String, origin: String, script: String, hardware: Boolean) = job {
		val result =
			engine.previewPublic(key.trim(), origin.trim(), script, hardware, mutable.value.network)
		change { it.copy(toolsResult = result) }
	}

	fun exportPublic(id: String) = job {
		val result = engine.exportPublic(id)
		change { it.copy(toolsResult = result) }
	}

	fun tool(op: String, fields: JSONObject = JSONObject()) = job {
		require(
			op in
				setOf(
					"addresses_onchain",
					"select_onchain_account",
					"sign_message_onchain",
					"receive_pending",
					"receive_status",
					"receive_claim",
					"offer_create",
					"offer_status",
					"offer_disable",
					"quote_board",
					"board",
					"recover",
					"coinjoin_status",
					"hardware_prepare",
					"hardware_import",
					"hardware_broadcast",
					"hardware_cancel",
					"ark_backend_check",
					"ark_hardware_import",
					"ark_hardware_commit",
					"ark_hardware_cancel",
				),
		)
		if (op in setOf("board", "hardware_broadcast", "ark_hardware_commit")) {
			val previous = engine.pending()
			check(
				previous == null ||
					PaymentStatus.from(previous.optString("state")) in
						listOf(PaymentStatus.COMPLETE, PaymentStatus.NOT_SENT),
			) {
				"Check the previous payment first"
			}
			val intent =
				JSONObject()
					.put("state", "unknown")
					.put("reason", "Transaction outcome needs checking")
			fields
				.optString("txid")
				.takeIf { it.matches(Regex("[0-9a-fA-F]{64}")) }
				?.let { intent.put("txid", it) }
			engine.savePending(intent)
			change { it.copy(result = intent) }
		}
		val result = engine.call(op, fields)
		if (op in setOf("board", "hardware_broadcast", "ark_hardware_commit")) {
			engine.savePending(result)
			change { it.copy(result = result) }
		}
		change {
			it.copy(
				toolsResult = result,
				review = null,
				connected = if (op == "select_onchain_account") false else it.connected,
				chain = if (op == "select_onchain_account") null else it.chain,
			)
		}
	}

	fun prepareHardwareBoard(sourceID: String, amount: String) = job {
		val result = engine.prepareHardwareBoard(sourceID, positiveAmount(amount))
		change { it.copy(toolsResult = result) }
	}

	fun clearTools() {
		change { it.copy(toolsResult = null) }
	}

	fun connect(settings: Connection) = job {
		change { it.copy(connected = false, review = null, ark = null) }
		engine.connect(settings)
		change { it.copy(connection = settings, connected = true) }
		refresh()
		startMaintenance()
	}

	private fun startMaintenance() {
		maintenance?.cancel()
		maintenance = viewModelScope.launch {
			while (true) {
				kotlinx.coroutines.delay(60000)
				if (
					!mutable.value.busy &&
						mutable.value.connected &&
						mutable.value.review == null &&
						mutable.value.toolsResult == null
				) {
					try {
						PaymentGate.run {
							refresh()
							if (
								getApplication<Application>()
									.getSharedPreferences("payment-options", 0)
									.getBoolean("maintenance", false) &&
									mutable.value.profiles
										.firstOrNull { it.id == mutable.value.activeID }
										?.kind == "hot"
							)
								engine.call("refresh")
						}
					} catch (e: kotlinx.coroutines.CancellationException) {
						throw e
					} catch (_: Exception) {
						change {
							it.copy(
								error =
									"Automatic refresh could not finish. Check the connection before retrying.",
							)
						}
					}
				}
			}
		}
	}

	private suspend fun refresh() {
		engine.call("sync_onchain")
		val chain = engine.call("overview_onchain")
		change { it.copy(chain = chain.getLong("total_sat")) }
		val activity = engine.call("activity")
		val rows = mutableListOf<String>()
		val onchain = activity.getJSONArray("onchain")
		for (i in 0 until onchain.length()) {
			val tx = onchain.getJSONObject(i)
			rows +=
				"${if (tx.getBoolean("confirmed")) "Confirmed" else "Pending"} · ${tx.getLong("change_sat")} sats\n${tx.getString("txid")}"
			val pending = mutable.value.result
			if (tx.getBoolean("confirmed") && pending?.optString("txid") == tx.getString("txid")) {
				val confirmed = JSONObject(pending.toString()).put("state", "completed")
				engine.savePending(confirmed)
				change { it.copy(result = confirmed) }
			}
		}
		val movements = activity.getJSONArray("movements")
		for (i in 0 until movements.length()) {
			val m = movements.getJSONObject(i)
			rows += "Ark · ${m.optString("status", "Recorded")}\n${m.optString("id")}"
		}
		change { it.copy(activity = rows, ark = null) }
		if (
			mutable.value.profiles.firstOrNull { it.id == mutable.value.activeID }?.kind in
				listOf("hardware", "watch")
		) {
			publishActivity(activity, chain.getString("account"))
			change { it.copy(ark = 0, expiryHeight = null) }
			return
		}
		val sync = engine.call("sync_ark")
		withContext(Dispatchers.IO) {
			ExpiryReminders.update(getApplication(), mutable.value.activeID, sync)
		}
		publishActivity(engine.call("activity"), chain.getString("account"))
		val vtxos = sync.getJSONArray("vtxos")
		val expiry =
			(0 until vtxos.length())
				.map { vtxos.getJSONObject(it).getLong("expiryHeight") }
				.minOrNull()
		change {
			it.copy(
				ark = sync.getLong("ark_sat"),
				activity = rows,
				expiryHeight = expiry,
				error =
					listOf("receive_warning", "recovery_warning")
						.mapNotNull { key ->
							if (sync.isNull(key)) null
							else sync.optString(key).takeIf { it.isNotEmpty() }
						}
						.joinToString("\n")
						.ifEmpty { null },
			)
		}
	}

	private suspend fun publishActivity(json: JSONObject, account: String) {
		val records = WalletActivity.parse(json)
		change { it.copy(activityRecords = records) }
		val id = mutable.value.activeID
		withContext(Dispatchers.IO) {
			runCatching { PaymentAlerts(getApplication()).observe(records, id, account) }
		}
	}

	fun sync() = job { refresh() }

	fun refreshArk() = job {
		engine.call("refresh")
		refresh()
	}

	fun checkExit() = job {
		val status = engine.call("exit_status")
		change { it.copy(exitStatus = status) }
	}

	fun startExit() = job {
		engine.call("exit_start", JSONObject().put("confirmed", true))
		val status = engine.call("exit_status")
		change { it.copy(exitStatus = status) }
	}

	fun progressExit() = job {
		engine.call("exit_progress")
		val status = engine.call("exit_status")
		change { it.copy(exitStatus = status) }
	}

	fun claimExit(destination: String) = job {
		val intent =
			JSONObject().put("state", "unknown").put("reason", "Exit claim outcome needs checking")
		engine.savePending(intent)
		change { it.copy(result = intent) }
		val result =
			engine.call(
				"exit_claim",
				JSONObject().put("confirmed", true).put("destination", destination.trim()),
			)
		engine.savePending(result)
		change { it.copy(result = result) }
		val status = engine.call("exit_status")
		change { it.copy(exitStatus = status) }
	}

	fun receive(kind: String, amount: String = "") = job {
		val result =
			when (kind) {
				"Ark" -> engine.call("address_ark")
				"Lightning" ->
					engine.call(
						"receive_lightning",
						JSONObject().put("amount_sat", positiveAmount(amount)),
					)
				else -> engine.call("address_onchain")
			}
		change { it.copy(address = result.optString("address", result.optString("invoice"))) }
	}

	fun clearReceive() {
		change { it.copy(address = "") }
	}

	fun quote(destination: String, amount: String, onchain: Boolean, sendMax: Boolean = false) =
		job {
			val pending = engine.pending()
			check(
				pending == null ||
					PaymentStatus.from(pending.optString("state")) in
						listOf(PaymentStatus.COMPLETE, PaymentStatus.NOT_SENT),
			) {
				"Check the previous payment before starting another one."
			}
			change { it.copy(review = null, reviewIssue = null, result = null) }
			val fields =
				JSONObject()
					.put("destination", PaymentInput.normalize(destination))
					.put("send_max", sendMax)
			if (!sendMax && amount.isNotBlank()) fields.put("amount_sat", positiveAmount(amount))
			val result =
				engine.call(
					if (onchain) "quote_onchain" else "quote",
					fields,
				)
			result.optJSONObject("review_issue")?.let { issue ->
				change { it.copy(reviewIssue = issue) }
				return@job
			}
			val quote =
				PaymentReview(
					PaymentInput.normalize(destination),
					result.getLong("amount_sat"),
					result.getLong("fee_sat"),
					result.getLong("total_sat"),
					onchain,
					SystemClock.elapsedRealtime(),
				)
			change { it.copy(review = quote) }
		}

	fun dismissResult() {
		val result = mutable.value.result ?: return
		if (
			PaymentStatus.from(result.optString("state")) in
				listOf(PaymentStatus.COMPLETE, PaymentStatus.NOT_SENT)
		)
			change { it.copy(result = null) }
	}

	fun cancelReview() {
		if (!mutable.value.busy) change { it.copy(review = null) }
	}

	fun send() = job {
		val previous = engine.pending()
		check(
			previous == null ||
				PaymentStatus.from(previous.optString("state")) in
					listOf(PaymentStatus.COMPLETE, PaymentStatus.NOT_SENT),
		) {
			"Check the previous payment before starting another one."
		}
		val quote = mutable.value.review ?: error("Review a payment first")
		check(quote.valid(SystemClock.elapsedRealtime())) { "Quote expired. Review again." }
		change { it.copy(review = null) }
		val intent =
			JSONObject()
				.put("state", "unknown")
				.put("destination", quote.destination)
				.put("amount_sat", quote.amount)
				.put("total_sat", quote.total)
		// A BOLT11 commitment is available before submission, even if the reply times out.
		if (!quote.onchain && quote.destination.lowercase().startsWith("lnbc"))
			runCatching { BridgeInvoice(quote.destination).hash }
				.getOrNull()
				?.let { intent.put("payment_hash", it) }
		engine.savePending(intent) // Durable before submission; never automatically retry a send.
		change { it.copy(result = intent) }
		try {
			val result =
				engine.call(
					if (quote.onchain) "send_onchain" else "send",
					JSONObject()
						.put("destination", quote.destination)
						.put("amount_sat", quote.amount)
						.put("total_sat", quote.total),
				)
			engine.savePending(result)
			change { it.copy(result = result) }
		} catch (e: Exception) {
			change {
				it.copy(error = "Payment outcome needs checking. ${e.message}", result = intent)
			}
		}
	}

	fun checkPayment() = job {
		val pending = mutable.value.result ?: return@job
		val hash = pending.optString("payment_hash")
		if (hash.isNotEmpty()) {
			val next =
				engine
					.call("check_payment", JSONObject().put("payment_hash", hash))
					.put("payment_hash", hash)
			engine.savePending(next)
			change { it.copy(result = next) }
		}
		refresh()
	}

	fun prepareBackup() = job {
		val key = BackupCodec.newKey()
		val bytes = engine.backup(key)
		change { it.copy(recoveryKey = key, backup = bytes, backupSaved = false) }
	}

	fun backupSaved() {
		change { it.copy(backupSaved = true) }
	}

	fun saveBackupFile(uri: Uri) = job {
		val bytes = mutable.value.backup ?: error("Prepare a new backup first")
		withContext(Dispatchers.IO) {
			getApplication<Application>().contentResolver.openOutputStream(uri)?.use {
				it.write(bytes)
			} ?: error("Could not save backup")
		}
		backupSaved()
	}

	fun restoreBackupFile(uri: Uri, key: String) = job {
		require(key.isNotBlank()) {
			"Recovery key was cleared. Select the backup again after unlocking."
		}
		val bytes =
			withContext(Dispatchers.IO) {
				getApplication<Application>().contentResolver.openInputStream(uri)?.use { input ->
					val output = java.io.ByteArrayOutputStream()
					val buffer = ByteArray(8192)
					while (true) {
						val count = input.read(buffer)
						if (count == -1) break
						require(output.size() + count <= BackupCodec.MAX_BYTES) {
							"Backup too large"
						}
						output.write(buffer, 0, count)
					}
					output.toByteArray()
				} ?: error("Could not read backup")
			}
		restoreArchive(bytes, key)
	}

	fun clearBackup() {
		mutable.value.backup?.fill(0)
		change { it.copy(backup = null, recoveryKey = "") }
	}

	private suspend fun restoreArchive(bytes: ByteArray, key: String) {
		try {
			engine.restore(bytes, key, testOnly)
		} finally {
			bytes.fill(0)
		}
		val chain = engine.open().getLong("total_sat")
		val network = checkNotNull(engine.network())
		val profiles = engine.profiles()
		val id = engine.activeID() ?: ""
		change {
			it.copy(
				hasWallet = true,
				chain = chain,
				network = network,
				profiles = profiles,
				activeID = id,
				ark = null,
				connected = false,
				review = null,
				result = null,
				activity = emptyList(),
				activityRecords = emptyList(),
				toolsResult = null,
			)
		}
	}

	fun lock() {
		generation++
		maintenance?.cancel()
		engine.cancelSync()
		// Keep only the encrypted export while Android's document picker is open.
		change {
			it.copy(phrase = "", recoveryKey = "", review = null, address = "", connected = false)
		}
		viewModelScope.launch { PaymentGate.run { engine.close() } }
	}

	companion object {
		fun positiveAmount(value: String): Long {
			require(value.matches(Regex("[0-9]+"))) { "Enter a whole number of sats" }
			return value.toLong().also {
				require(it > 0 && it <= 2_100_000_000_000_000L) {
					"Amount is outside the valid range"
				}
			}
		}
	}
}
