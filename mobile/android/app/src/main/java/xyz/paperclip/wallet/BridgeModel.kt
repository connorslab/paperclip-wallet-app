package xyz.paperclip.wallet

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal data class BridgeState(
	val busy: Boolean = false,
	val message: String = "",
	val record: JSONObject? = null,
	val nativeQuote: JSONObject? = null,
	val nodeReview: NodeInvoiceReview? = null,
	val history: List<JSONObject> = emptyList(),
	val quoteRevision: Long = 0,
)

internal class BridgeModel(app: Application) : AndroidViewModel(app) {
	private val vault = SecureStore(app)
	private val engine = WalletEngine.shared(app)
	private val mutable = MutableStateFlow(BridgeState())
	val state = mutable.asStateFlow()
	private var journal = JSONArray()
	private var loaded = false
	private var poll: Job? = null
	private var foreground = false
	private val mutableHealth = MutableStateFlow<Map<Boolean, BridgeHealth>>(emptyMap())
	val serviceHealth = mutableHealth.asStateFlow()
	private val healthRequests = mutableMapOf<Boolean, Job>()
	private var healthGeneration = 0L

	fun refreshAvailability(receiveXbt: Boolean): Job? {
		healthRequests[receiveXbt]?.let { return it }
		if (!(mutableHealth.value[receiveXbt] ?: BridgeHealth()).shouldRefresh(android.os.SystemClock.elapsedRealtime())) return null
		val ticket = healthGeneration
		mutableHealth.value = mutableHealth.value + (receiveXbt to BridgeHealth(checking = true))
		return viewModelScope.launch(start = CoroutineStart.LAZY) {
			var open: Boolean? = null
			try {
				val result = client().availability(receiveXbt)
				open = result.opt("open") as? Boolean ?: error("Invalid availability response")
			} catch (e: CancellationException) { throw e }
			catch (_: Exception) { /* Unreachable or malformed is unknown, never live or paused. */ }
			finally {
				if (ticket == healthGeneration) {
					mutableHealth.value = mutableHealth.value + (receiveXbt to BridgeHealth(open, android.os.SystemClock.elapsedRealtime()))
					healthRequests.remove(receiveXbt)
				}
			}
		}.also { healthRequests[receiveXbt] = it; it.start() }
	}
	private fun clearAvailability() {
		healthGeneration++
		healthRequests.values.forEach { it.cancel() }; healthRequests.clear()
		mutableHealth.value = emptyMap()
	}

	private fun change(f: (BridgeState) -> BridgeState) {
		mutable.value = f(mutable.value)
	}

	private var generation = 0L
	private val reviewSession = PaymentReviewSession()
	private var approval: UUID? = null

	private fun job(block: suspend () -> Unit) {
		if (mutable.value.busy) return
		change { it.copy(busy = true, message = "") }
		val ticket = generation
		viewModelScope.launch {
			try {
				PaymentGate.run {
					if (generation != ticket) throw CancellationException()
					block()
				}
			} catch (e: CancellationException) {
				throw e
			} catch (e: Exception) {
				change { it.copy(message = e.message ?: "Bridge request failed") }
			} finally {
				change { it.copy(busy = false) }
			}
		}
	}

	private suspend fun read(name: String) =
		withContext(Dispatchers.IO) {
			vault.read(name)?.let { bytes ->
				try {
					String(bytes)
				} finally {
					bytes.fill(0)
				}
			}
		}

	private suspend fun write(name: String, value: String) =
		withContext(Dispatchers.IO) {
			val bytes = value.toByteArray()
			try {
				vault.write(name, bytes)
			} finally {
				bytes.fill(0)
			}
		}

	private suspend fun client() = LightningBridge(read("bridge-api-key") ?: "")

	private suspend fun loadJournal() {
		if (!loaded) {
			journal = read("bridge-records")?.let(::JSONArray) ?: JSONArray()
			loaded = true
			change {
				it.copy(
					history = historySnapshot(),
					record =
						if (journal.length() > 0) journal.getJSONObject(journal.length() - 1)
						else null,
				)
			}
		}
	}

	private suspend fun save(record: JSONObject) {
		check(loaded)
		val next = JSONArray()
		for (i in 0 until journal.length()) {
			val old = journal.getJSONObject(i)
			if (old.getString("hash") != record.getString("hash")) next.put(old)
		}
		next.put(record)
		write("bridge-records", next.toString())
		journal = next
		change { it.copy(record = record, history = historySnapshot()) }
	}
	private fun historySnapshot() = (journal.length() - 1 downTo 0).map {
		JSONObject(journal.getJSONObject(it).toString())
	}

	fun selectSaved(hash: String) = job {
		loadJournal()
		val record = historySnapshot().firstOrNull { it.optString("hash") == hash }
			?: error("Saved bridge payment is unavailable")
		// A historical quote never restores an old authorization to fund it.
		reviewSession.invalidate(); approval = null
		change { it.copy(record = record, nativeQuote = null, nodeReview = null) }
	}

	private fun unsettled(r: JSONObject) =
		r.optBoolean("submitted") &&
			!r.optBoolean("verified") &&
			!(r.optBoolean("receive") && r.optString("node_state") == "ended") &&
			!(r.optString("funding") in listOf("failed", "not_sent") &&
				r.optString("bridge") in listOf("failed", "aborted", "expired"))

	private suspend fun node(): LightningNode {
		val c =
			read("lightning-connection")?.let { NodeConnection.from(JSONObject(it)) }
				?: error("Connect a Lightning node first")
		return LightningNode.open(getApplication(), c).also {
			require(
				NodeNetwork.decode(it.info(), c.implementation == "lnd") == NodeNetwork.MAINNET,
			) {
				"The bridge requires an XBT mainnet node"
			}
		}
	}

	fun load() = job {
		foreground = true
		loadJournal()
		startPolling()
	}

	fun quote(
		targetText: String,
		source: String,
		receiveXbt: Boolean,
		amount: String,
		fee: String,
	) {
		if (mutable.value.busy) return
		invalidateReview()
		// Capture before waiting for another wallet operation in PaymentGate.
		val ticket = reviewSession.capture()
		job {
			reviewSession.check(ticket)
			loadJournal()
			require(source in listOf("ark", "node"))
			check((0 until journal.length()).none { unsettled(journal.getJSONObject(it)) }) {
				"Check the existing bridge payment before creating another"
			}
			change { it.copy(nativeQuote = null, nodeReview = null) }
			val n = if (source == "node" || receiveXbt) node() else null
			reviewSession.check(ticket)
			val requestedAmount = if (receiveXbt) WalletModel.positiveAmount(amount) else null
			val target =
				BridgeInvoice(
					if (receiveXbt) checkNotNull(n).invoice(checkNotNull(requestedAmount))
					else targetText,
				)
			reviewSession.check(ticket)
			target.validateTarget(receiveXbt)
			if (receiveXbt) {
				target.validateNodeReceive(checkNotNull(requestedAmount), checkNotNull(n).receivedInvoice(target))
			}
			check(
				(0 until journal.length()).none {
					journal.getJSONObject(it).let { r ->
						r.getString("hash") == target.hash && r.optBoolean("submitted")
					}
				},
			) {
				"This invoice already has a recorded payment attempt"
			}
			reviewSession.check(ticket)
			val quote = client().quote(target, receiveXbt)
			reviewSession.check(ticket)
			val hold = quote.validate(target, receiveXbt)
			val record =
				JSONObject()
					.put("hash", target.hash)
					.put("target", target.text)
					.put("quote", quote.value)
					.put("source", source)
					.put("receive", receiveXbt)
					.put("wallet", engine.activeID())
					.put("submitted", receiveXbt)
					.put("funding", "not_sent")
					.put("bridge", "quoted")
					.put("private_api", !read("bridge-api-key").isNullOrEmpty())
			if (n != null)
				record
					.put("node_endpoint", n.connection.endpoint)
					.put("node_implementation", n.connection.implementation)
			var nativeApproval: JSONObject? = null
			var nodeApproval: NodeInvoiceReview? = null
			if (!receiveXbt && source == "ark") {
				require(engine.network() == "xbt-mainnet")
				val native =
					engine.call(
						"quote",
						JSONObject()
							.put("destination", hold.text)
							.put("amount_sat", (hold.msat + 999) / 1000),
					)
				require(
					native.has("total_sat") && native.getLong("amount_sat") == (hold.msat + 999) / 1000,
				)
				nativeApproval = native
			} else if (!receiveXbt) {
				val review =
					checkNotNull(n)
						.review(
							hold.text,
							null,
							fee.toLongOrNull() ?: error("Enter a maximum routing fee"),
						)
				require(review.hash == hold.hash && review.msat == hold.msat)
				nodeApproval = review
			}
			reviewSession.check(ticket)
			save(record)
			reviewSession.check(ticket)
			approval = ticket
			change { it.copy(nativeQuote = nativeApproval, nodeReview = nodeApproval, quoteRevision = it.quoteRevision + 1) }
			startPolling()
		}
	}

	fun fund() = job {
		val ticket = approval ?: error("Review this bridge payment again")
		reviewSession.check(ticket)
		loadJournal()
		val old = mutable.value.record ?: error("Review a quote first")
		check(!old.optBoolean("receive") && !old.optBoolean("submitted")) {
			"This quote already has a payment attempt"
		}
		val target = BridgeInvoice(old.getString("target"))
		val hold = BridgeQuote(old.getJSONObject("quote")).validate(target, false)
		val source = old.getString("source")
		val native = mutable.value.nativeQuote
		val review = mutable.value.nodeReview
		if (source == "ark") {
			check(engine.activeID() == old.getString("wallet"))
			check(native != null)
		} else {
			check(review != null && review.valid())
		}
		val n =
			if (source == "node")
				node().also {
					require(
						it.connection.endpoint == old.getString("node_endpoint") &&
							it.connection.implementation == old.getString("node_implementation"),
					)
				}
			else null
		if (source == "ark") {
			val previous = engine.pending()
			check(
				previous == null ||
					PaymentStatus.from(previous.optString("state")) in
						listOf(PaymentStatus.COMPLETE, PaymentStatus.NOT_SENT),
			) {
				"Check the previous wallet payment first"
			}
		} else {
			val previous = read("lightning-pending")?.let(::JSONObject)
			check(
				previous == null || previous.optString("state") in listOf("succeeded", "failed"),
			) {
				"Check the existing outgoing node payment first"
			}
		}
		reviewSession.check(ticket)
		val intent = JSONObject(old.toString()).put("submitted", true).put("funding", "unknown")
		save(intent) // Durable before either funding call; never replayed automatically.
		// Past this durable boundary, finish and reconcile even if the UI locks.
		approval = null
		change { it.copy(nativeQuote = null, nodeReview = null) }
		try {
			val funding =
				if (source == "ark") {
					// The native send journals funding before submission; this Bridge
					// record above independently retains the conversion's unknown state.
					val result =
						engine.call(
							"send",
							JSONObject()
								.put("destination", hold.text)
								.put("amount_sat", native!!.getLong("amount_sat"))
								.put("total_sat", native.getLong("total_sat")),
						)
					result.put("payment_hash", hold.hash)
					engine.savePending(result)
					result.optString("state", "unknown")
				} else {
					val nodeIntent =
						JSONObject()
							.put("hash", hold.hash)
							.put("invoice", hold.text)
							.put("amount_msat", hold.msat.toString())
							.put("maximum_fee_sat", review!!.feeSat.toString())
							.put("state", "unknown")
							.put("endpoint", n!!.connection.endpoint)
							.put("implementation", n.connection.implementation)
					write("lightning-pending", nodeIntent.toString())
					val result = n.pay(review)
					val state = NodePaymentStatus.decode(result, hold.hash)
					if (state != null) {
						nodeIntent.put("state", state)
						write("lightning-pending", nodeIntent.toString())
					}
					state ?: "unknown"
				}
			save(JSONObject(intent.toString()).put("funding", funding))
		} finally {
			startPolling()
		}
	}

	fun check() = job { refresh() }

	private suspend fun reconcileFunding(record: JSONObject) {
		if (!record.optBoolean("submitted") || record.optBoolean("receive")) return
		val hash = record.getString("hash")
		if (record.getString("source") == "ark") {
			require(engine.activeID() == record.getString("wallet")) {
				"Select the original wallet to check bridge funding"
			}
			val result = engine.call("check_payment", JSONObject().put("payment_hash", hash))
			record.put("funding", result.optString("state", "unknown"))
			// Do not overwrite a newer, unrelated wallet payment.
			if (engine.pending()?.optString("payment_hash") == hash)
				engine.savePending(result.put("payment_hash", hash))
		} else {
			val n = node()
			require(
				n.connection.endpoint == record.getString("node_endpoint") &&
					n.connection.implementation == record.getString("node_implementation"),
			)
			val state = NodePaymentStatus.decode(n.track(hash), hash) ?: return
			record.put("funding", state)
			val pending = read("lightning-pending")?.let(::JSONObject)
			if (pending?.optString("hash") == hash)
				write("lightning-pending", pending.put("state", state).toString())
		}
	}

	private suspend fun refresh() {
		loadJournal()
		val r = mutable.value.record ?: return
		if (r.optBoolean("verified")) return
		val observation = BridgeSettlement.observe(r,
			bridge = {
				require(r.optBoolean("private_api") == !read("bridge-api-key").isNullOrEmpty()) { "Restore the original bridge API connection" }
				client().status(BridgeQuote(r.getJSONObject("quote")))
			},
			receive = {
				val n = node()
				require(n.connection.endpoint == r.getString("node_endpoint") && n.connection.implementation == r.getString("node_implementation"))
				n.receivedInvoice(BridgeInvoice(r.getString("target")))
			},
			funding = { reconcileFunding(it) },
		)
		save(observation.record)
		change { it.copy(message = observation.message) }
	}

	fun saveKey(value: String) = job {
		loadJournal()
		require(value.isEmpty() || (value.length in 32..512 && value.none { it.isWhitespace() }))
		check((0 until journal.length()).none { unsettled(journal.getJSONObject(it)) }) {
			"Finish pending bridge payments before changing access"
		}
		write("bridge-api-key", value)
		clearAvailability()
		invalidateReview()
	}

	private fun startPolling() {
		poll?.cancel()
		if (!foreground) return
		poll = viewModelScope.launch {
			while (isActive) {
				delay(15000)
				if (!mutable.value.busy)
					try {
						PaymentGate.run { refresh() }
					} catch (e: CancellationException) {
						throw e
					} catch (_: Exception) {
						change {
							it.copy(
								message =
									"Status unavailable. The saved payment has not been resent.",
							)
						}
					}
			}
		}
	}

	fun invalidateReview() {
		reviewSession.invalidate(); approval = null
		change { it.copy(nativeQuote = null, nodeReview = null) }
	}

	fun lock() {
		invalidateReview()
		clearAvailability()
		generation++
		foreground = false
		poll?.cancel()
	}
}
