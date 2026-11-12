package xyz.paperclip.wallet

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

data class LightningState(
	val connection: NodeConnection = NodeConnection(),
	val connected: Boolean = false,
	val mainnet: Boolean = false,
	val busy: Boolean = false,
	val message: String = "",
	val balance: NodeBalance? = null,
	val review: NodeInvoiceReview? = null,
	val invoice: String = "",
	val pending: JSONObject? = null,
)

class LightningModel(app: Application) : AndroidViewModel(app) {
	private val vault = SecureStore(app)
	private var node: LightningNode? = null
	private val mutable = MutableStateFlow(LightningState())
	val state = mutable.asStateFlow()
	private var poll: Job? = null
	private var foreground = false

	private fun change(f: (LightningState) -> LightningState) {
		mutable.value = f(mutable.value)
	}

	private var generation = 0L

	private fun work(block: suspend () -> Unit) {
		if (mutable.value.busy) return
		change { it.copy(busy = true, message = "") }
		val ticket = generation
		viewModelScope.launch {
			try {
				PaymentGate.run {
					if (generation != ticket) throw kotlinx.coroutines.CancellationException()
					block()
				}
			} catch (e: CancellationException) {
				throw e
			} catch (e: Exception) {
				change { it.copy(message = e.message ?: "Node request failed") }
			} finally {
				change { it.copy(busy = false) }
			}
		}
	}

	private suspend fun read(name: String) =
		withContext(Dispatchers.IO) {
			vault.read(name)?.let { bytes ->
				try {
					JSONObject(String(bytes, Charsets.UTF_8))
				} finally {
					bytes.fill(0)
				}
			}
		}

	private suspend fun save(name: String, j: JSONObject) =
		withContext(Dispatchers.IO) {
			val bytes = j.toString().toByteArray()
			try {
				vault.write(name, bytes)
			} finally {
				bytes.fill(0)
			}
		}

	fun load() = work {
		foreground = true
		val c = read("lightning-connection")?.let(NodeConnection::from) ?: NodeConnection()
		val pending = read("lightning-pending")
		change { it.copy(connection = c, pending = pending) }
		if (c.endpoint.isNotEmpty()) connectStored(c)
	}

	fun connect(c: NodeConnection) = work {
		val stored = read("lightning-pending")
		change { it.copy(pending = stored) }
		check(!unresolved()) { "Resolve the pending payment before changing nodes" }
		c.validate()
		save("lightning-connection", c.json())
		change { it.copy(connection = c, connected = false, review = null, balance = null) }
		node = null
		connectStored(c)
	}

	private suspend fun connectStored(c: NodeConnection) {
		val client = LightningNode.open(getApplication(), c)
		val info = client.info()
		require(
			info
				.optString(if (c.implementation == "lnd") "identity_pubkey" else "id")
				.matches(Regex("[0-9a-fA-F]{66}")),
		) {
			"Invalid node identity"
		}
		val network = NodeNetwork.decode(info, c.implementation == "lnd")
		node = client
		change { it.copy(connected = true, mainnet = network == NodeNetwork.MAINNET) }
		refreshBalance()
		startPolling()
	}

	private suspend fun refreshBalance() {
		val balance = checkNotNull(node).balance()
		change { it.copy(balance = balance) }
	}

	fun refresh() = work { refreshBalance() }

	fun receive(amount: String, offer: Boolean, description: String) = work {
		val c = checkNotNull(node) { "Connect your node first" }
		val sats = if (amount.isBlank() && offer) null else WalletModel.positiveAmount(amount)
		val invoice = if (offer) c.offer(sats, description) else c.invoice(checkNotNull(sats))
		change { it.copy(invoice = invoice) }
	}

	fun clearReview() {
		if (!mutable.value.busy) change { it.copy(review = null, invoice = "") }
	}

	fun review(invoice: String, amount: String, fee: String) = work {
		val stored = read("lightning-pending")
		change { it.copy(pending = stored) }
		check(!unresolved()) { "Check your pending payment before starting another" }
		change { it.copy(review = null) }
		val cap = fee.toLongOrNull() ?: error("Enter a maximum fee in whole sats")
		val review =
			checkNotNull(node)
				.review(
					PaymentInput.normalize(invoice),
					amount.takeIf { it.isNotBlank() }?.let(WalletModel::positiveAmount),
					cap,
				)
		change { it.copy(review = review) }
	}

	private fun unresolved() =
		mutable.value.pending?.optString("state")?.let { it !in listOf("succeeded", "failed") }
			?: false

	fun send() = work {
		val stored = read("lightning-pending")
		change { it.copy(pending = stored) }
		check(!unresolved())
		val r = mutable.value.review ?: error("Review the invoice first")
		require(r.valid()) { "Invoice expired. Review again." }
		val c = mutable.value.connection
		val pending =
			JSONObject()
				.put("hash", r.hash)
				.put("invoice", r.invoice)
				.put("amount_msat", r.msat.toString())
				.put("maximum_fee_sat", r.feeSat.toString())
				.put("state", "unknown")
				.put("endpoint", c.endpoint)
				.put("implementation", c.implementation)
		save("lightning-pending", pending)
		change { it.copy(pending = pending, review = null) }
		try {
			applyResult(checkNotNull(node).pay(r))
		} finally {
			startPolling()
		}
	}

	private suspend fun applyResult(response: JSONObject) {
		val pending = mutable.value.pending ?: return
		val hash = pending.getString("hash")
		val status = NodePaymentStatus.decode(response, hash) ?: return
		val terminal = status in listOf("succeeded", "failed")
		val next = JSONObject(pending.toString()).put("state", status)
		save("lightning-pending", next)
		change { it.copy(pending = next) }
		if (terminal) refreshBalance()
	}

	fun checkPayment() = work { checkStored() }

	private suspend fun checkStored() {
		val p = read("lightning-pending") ?: return
		change { it.copy(pending = p) }
		val c = mutable.value.connection
		require(
			p.getString("endpoint") == c.endpoint &&
				p.getString("implementation") == c.implementation,
		) {
			"Reconnect the original node to check this payment"
		}
		applyResult(checkNotNull(node).track(p.getString("hash")))
	}

	private fun startPolling() {
		poll?.cancel()
		if (!foreground || !unresolved()) return
		poll = viewModelScope.launch {
			while (foreground && unresolved()) {
				delay(15000)
				if (!mutable.value.busy) {
					try {
						PaymentGate.run { checkStored() }
					} catch (e: CancellationException) {
						throw e
					} catch (_: Exception) {
						change {
							it.copy(
								message =
									"Payment status could not be refreshed. The attempt remains recorded; no payment was retried.",
							)
						}
					}
				}
			}
		}
	}

	fun lock() {
		generation++
		foreground = false
		poll?.cancel()
		change { it.copy(review = null, invoice = "") }
	}
}
