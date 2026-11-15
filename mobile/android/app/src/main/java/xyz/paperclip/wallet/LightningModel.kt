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
	val connecting: Boolean = false,
	val message: String = "",
	val connectionStatus: String = "Not connected",
	val checkedAt: Long? = null,
	val balanceStale: Boolean = false,
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
	private var workJob: Job? = null
	private var balancePoll: Job? = null
	private var foreground = false

	private fun change(f: (LightningState) -> LightningState) {
		mutable.value = f(mutable.value)
	}

	private var generation = 0L

	private fun work(block: suspend () -> Unit) {
		if (mutable.value.busy) return
		change { it.copy(busy = true, message = "") }
		val ticket = generation
		workJob = viewModelScope.launch {
			try {
				PaymentGate.run {
					if (generation != ticket) throw kotlinx.coroutines.CancellationException()
					block()
				}
			} catch (e: CancellationException) {
				throw e
			} catch (e: Exception) {
				if (generation == ticket) change { it.copy(message = e.message ?: "Node request failed") }
			} finally {
				if (generation == ticket) change { it.copy(busy = false) }
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
		// Keep the saved node until the replacement passes TLS, authentication and network checks.
		connectStored(c, persist = true)
	}

	private fun connectionFailure(error: Exception, c: NodeConnection): String = when (error) {
		is java.io.InterruptedIOException ->
			if (c.proxy.isNotEmpty()) "The node did not respond through Tor. Check its REST address, port, and availability over Tor. Your saved settings have been kept."
			else "The node did not respond. Check its REST address and port, and that this device can reach your node’s network. Your saved settings have been kept."
		is java.net.UnknownHostException -> "The node address could not be resolved. Check the hostname and network; .onion addresses require Tor."
		else -> error.message ?: "Node request failed"
	}

	private suspend fun connectStored(c: NodeConnection, persist: Boolean = false) {
		change { it.copy(connecting = true) }
		try {
			verifyConnection(c, persist)
		} catch (e: CancellationException) {
			change { it.copy(connectionStatus = "Connection check cancelled") }
			throw e
		} catch (e: Exception) {
			change {
				it.copy(connectionStatus = "Connection needs attention", balanceStale = it.balance != null)
			}
			throw IllegalStateException(connectionFailure(e, c), e)
		} finally { change { it.copy(connecting = false) } }
	}

	fun cancelConnection() {
		if (mutable.value.connecting) workJob?.cancel()
	}

	private suspend fun verifyConnection(c: NodeConnection, persist: Boolean) {
		change { it.copy(connectionStatus = if (c.proxy.isEmpty()) "Contacting node…" else "Connecting through Tor…") }
		val client = LightningNode.open(getApplication(), c)
		change { it.copy(connectionStatus = "Verifying node access…") }
		val info = client.info()
		require(
			info
				.optString(if (c.implementation == "lnd") "identity_pubkey" else "id")
				.matches(Regex("0[23][0-9a-fA-F]{64}")),
		) {
			"Invalid node identity"
		}
		val network = NodeNetwork.decode(info, c.implementation == "lnd")
		if (persist) save("lightning-connection", c.json())
		node = client
		change {
			it.copy(
				connection = c, connected = true, mainnet = network == NodeNetwork.MAINNET,
				connectionStatus = "Node connected", checkedAt = System.currentTimeMillis(),
				review = null, balance = if (it.connection == c) it.balance else null,
			)
		}
		startPolling()
		startBalancePolling()
		refreshBalance()
	}

	private fun startBalancePolling() {
		balancePoll?.cancel()
		if (!foreground) return
		balancePoll = viewModelScope.launch {
			while (foreground) {
				delay(60000)
				if (!mutable.value.busy) {
					try { PaymentGate.run { refreshBalance() } }
					catch (e: CancellationException) { throw e }
					catch (_: Exception) { /* Last known balance remains labelled stale. */ }
				}
			}
		}
	}

	private suspend fun refreshBalance() {
		try {
			val balance = checkNotNull(node).balance()
			change {
				it.copy(balance = balance, balanceStale = false, connectionStatus = "Node connected",
					checkedAt = System.currentTimeMillis())
			}
		} catch (e: CancellationException) { throw e }
		catch (e: Exception) {
			val message = connectionFailure(e, mutable.value.connection)
			change { it.copy(balanceStale = it.balance != null, connectionStatus = "Connection needs attention", message = message) }
			throw IllegalStateException(message, e)
		}
	}

	fun refresh() = work {
		val c = mutable.value.connection
		check(c.endpoint.isNotBlank()) { "Connect your node first" }
		connectStored(c)
	}

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
		balancePoll?.cancel()
		workJob?.cancel()
		change { it.copy(review = null, invoice = "", busy = false) }
	}
}
