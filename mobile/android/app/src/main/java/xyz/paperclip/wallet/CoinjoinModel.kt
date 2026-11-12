package xyz.paperclip.wallet

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import java.net.URI
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

internal data class CoinjoinState(
	val snapshot: JSONObject = JSONObject(),
	val pools: List<JSONObject> = emptyList(),
	val connected: Boolean = false,
	val busy: Boolean = false,
	val message: String = "",
	val quote: JSONObject? = null,
)

internal class CoinjoinModel(app: Application) : AndroidViewModel(app) {
	private val engine = WalletEngine.shared(app)
	private val mutable = MutableStateFlow(CoinjoinState())
	val state = mutable.asStateFlow()
	private var wallet = ""
	private var socket: BoundedRelay? = null
	private var ticker: Job? = null
	private var generation = 0L
	private var route: String? = null
	private var relay = ""
	private var useTor = true
	private val outputs = mutableMapOf<String, BoundedRelay>()
	private val attempts = mutableMapOf<String, Long>()
	private val announcements = mutableMapOf<String, JSONObject>()
	private var subscribed = ""
	private var replaying = false
	private var replayBytes = 0
	private val replay = mutableListOf<JSONObject>()

	private fun change(f: (CoinjoinState) -> CoinjoinState) {
		mutable.value = f(mutable.value)
	}

	private fun rows(key: String): List<JSONObject> {
		val a = mutable.value.snapshot.optJSONArray(key) ?: JSONArray()
		return (0 until a.length()).map { a.getJSONObject(it) }
	}

	private fun active() = rows("rounds").firstOrNull { it.optBoolean("active") }

	private suspend fun call(op: String, fields: JSONObject = JSONObject()) =
		engine.callForWallet(wallet, op, fields)

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
				change { it.copy(message = e.message ?: "Coinjoin operation failed") }
			} finally {
				change { it.copy(busy = false) }
			}
		}
	}

	fun load(id: String) = job {
		if (wallet != id) {
			stop()
			wallet = id
			announcements.clear()
		}
		val snapshot = call("coinjoin_status")
		change { it.copy(snapshot = snapshot) }
	}

	fun action(op: String, fields: JSONObject = JSONObject()) = job {
		require(
			op in
				setOf(
					"coinjoin_address",
					"coinjoin_sync",
					"coinjoin_recover",
					"coinjoin_create",
					"coinjoin_join",
					"coinjoin_close",
					"coinjoin_vote",
					"coinjoin_leave",
					"coinjoin_sign",
					"coinjoin_broadcast",
					"coinjoin_quote",
					"coinjoin_transfer",
					"coinjoin_migrate",
				),
		)
		if (op in setOf("coinjoin_create", "coinjoin_join"))
			fields.put("relay", relay).put("tor", useTor)
		if (op in setOf("coinjoin_create", "coinjoin_join", "coinjoin_sign"))
			check(mutable.value.connected) { "Connect to the relay first" }
		if (op == "coinjoin_migrate") call("coinjoin_sync")
		val result = call(op, fields)
		if (op == "coinjoin_quote") change { it.copy(quote = result) }
		else {
			val snapshot = call("coinjoin_status")
			change { it.copy(snapshot = snapshot, quote = null) }
		}
		subscribe()
		flush()
	}

	fun clearQuote() {
		change { it.copy(quote = null) }
	}

	fun connect(url: String, tor: Boolean) = job {
		stop()
		val round = active()
		relay = round?.optString("relay")?.takeIf { it.isNotEmpty() } ?: url
		useTor = round?.optBoolean("tor") ?: tor
		val uri = URI(relay)
		require(
			uri.scheme == "wss" &&
				uri.host != null &&
				uri.rawUserInfo == null &&
				uri.rawQuery == null &&
				uri.rawFragment == null,
		)
		require(!uri.host.endsWith(".onion") || useTor)
		val ticket = generation
		route = if (useTor) EmbeddedTor.proxy(getApplication()) else null
		if (generation != ticket) throw CancellationException()
		socket = open(ticket, null)
		ticker = viewModelScope.launch {
			var ticks = 0
			var reconnectAt = System.currentTimeMillis() + 30000
			while (isActive && generation == ticket) {
				delay(5000)
				if (!mutable.value.connected && System.currentTimeMillis() >= reconnectAt) {
					socket?.cancel()
					subscribed = ""
					socket = open(ticket, null)
					reconnectAt = System.currentTimeMillis() + 30000
				}
				if (!mutable.value.busy && mutable.value.connected) {
					try {
						PaymentGate.run {
							if (generation != ticket) return@run
							if (++ticks % 6 == 0) call("coinjoin_sync")
							val snapshot = call("coinjoin_tick")
							change { it.copy(snapshot = snapshot) }
							subscribe()
							flush()
							updatePools()
						}
					} catch (e: CancellationException) {
						throw e
					} catch (_: Exception) {
						change {
							it.copy(
								message =
									"Coinjoin state could not refresh. Reconnect to resume the saved round.",
							)
						}
					}
				}
			}
		}
	}

	private val queued = java.util.concurrent.atomic.AtomicInteger(0)

	private fun current(ticket: Long, connection: BoundedRelay, event: JSONObject?): Boolean =
		generation == ticket &&
			if (event == null) socket === connection
			else outputs[event.getString("id")] === connection

	private fun open(ticket: Long, event: JSONObject?): BoundedRelay {
		lateinit var link: BoundedRelay
		link =
			BoundedRelay(
				URI(relay),
				route,
				opened = { connection ->
					viewModelScope.launch {
						if (!current(ticket, connection, event)) {
							connection.cancel()
							return@launch
						}
						try {
							if (event != null) send(connection, JSONArray().put("EVENT").put(event))
							else {
								change {
									it.copy(
										connected = true,
										message =
											"Connected. Keep this page open during the round.",
									)
								}
								send(
									connection,
									JSONArray()
										.put("REQ")
										.put("pools")
										.put(
											JSONObject()
												.put("kinds", JSONArray().put(32022))
												.put("#t", JSONArray().put("kilojoin"))
												.put("limit", 500),
										),
								)
								PaymentGate.run {
									if (current(ticket, connection, event)) {
										subscribe()
										flush()
									}
								}
							}
						} catch (e: CancellationException) {
							throw e
						} catch (_: Exception) {
							connection.cancel()
							if (current(ticket, connection, event))
								change {
									it.copy(
										connected = false,
										message =
											"Relay connection could not resume the saved round.",
									)
								}
						}
					}
				},
				received = { connection, text ->
					if (queued.incrementAndGet() > 32) {
						queued.decrementAndGet()
						connection.cancel()
						viewModelScope.launch {
							if (current(ticket, connection, event) && event == null)
								change { it.copy(connected = false) }
						}
					} else
						viewModelScope.launch {
							try {
								PaymentGate.run {
									if (current(ticket, connection, event)) receive(JSONArray(text))
								}
							} catch (e: CancellationException) {
								throw e
							} catch (_: Exception) {
								if (current(ticket, connection, event))
									change {
										it.copy(
											message =
												"Relay message rejected; the saved round remains unchanged.",
										)
									}
							} finally {
								queued.decrementAndGet()
							}
						}
				},
				failed = {
					viewModelScope.launch {
						if (current(ticket, link, event))
							change {
								it.copy(
									connected = if (event == null) false else it.connected,
									message =
										"Relay disconnected. Reconnect to resume the saved round.",
								)
							}
					}
				},
			)
		link.connect()
		return link
	}

	private fun send(link: BoundedRelay?, message: JSONArray) {
		val text = message.toString()
		require(text.toByteArray().size <= 524288)
		check(link?.send(text) == true) { "Relay is disconnected" }
	}

	private fun subscribe() {
		if (!mutable.value.connected) return
		val r = active() ?: return
		val key =
			r.getString("id") + if (r.optString("phase") == "joining") "-joining" else "-welcomed"
		if (key == subscribed) return
		subscribed = key
		replay.clear()
		replayBytes = 0
		replaying = true
		send(
			socket,
			JSONArray()
				.put("REQ")
				.put("round")
				.put(
					JSONObject()
						.put("kinds", JSONArray().put(2023))
						.put("#p", r.getJSONArray("subscriptions")),
				),
		)
	}

	private suspend fun receive(value: JSONArray) {
		when (value.optString(0)) {
			"EVENT" -> {
				require(value.length() == 3)
				val event = value.getJSONObject(2)
				if (value.getString(1) == "pools") {
					val checked = call("coinjoin_pool", JSONObject().put("event", event))
					val terms = checked.getJSONObject("terms")
					val key = terms.getString("public_key") + terms.getString("id")
					val old = announcements[key]
					if (
						old == null ||
							checked.getLong("created_at") > old.getLong("created_at") ||
							(checked.getLong("created_at") == old.getLong("created_at") &&
								checked.getString("event_id") < old.getString("event_id"))
					) {
						require(announcements.size < 1000 || old != null)
						announcements[key] = checked.put("event", event)
						updatePools()
					}
				} else if (value.getString(1) == "round") {
					if (replaying) {
						replayBytes += event.toString().toByteArray().size
						require(replay.size < 20000 && replayBytes < 16 * 1024 * 1024)
						replay += event
					} else {
						process(event)
						subscribe()
						flush()
					}
				}
			}
			"EOSE" ->
				if (value.optString(1) == "round") {
					val events = replay.sortedBy { it.optLong("created_at") }
					replay.clear()
					replayBytes = 0
					replaying = false
					for (event in events) process(event)
					subscribe()
					flush()
				}
			"OK" ->
				if (value.optBoolean(2)) {
					val eventID = value.getString(1)
					val r =
						rows("rounds").firstOrNull { round ->
							val out = round.getJSONArray("outbox")
							(0 until out.length()).any {
								out.getJSONObject(it).getJSONObject("event").getString("id") ==
									eventID
							}
						}
					if (r != null) {
						val snapshot =
							call(
								"coinjoin_ack",
								JSONObject().put("id", r.getString("id")).put("event_id", eventID),
							)
						change { it.copy(snapshot = snapshot) }
						outputs.remove(eventID)?.cancel()
						subscribe()
					}
				}
			"CLOSED" ->
				change {
					it.copy(
						connected = false,
						message = "Relay subscription closed. Reconnect to resume.",
					)
				}
		}
	}

	private suspend fun process(event: JSONObject) {
		val id = active()?.getString("id") ?: return
		val snapshot = call("coinjoin_event", JSONObject().put("id", id).put("event", event))
		change { it.copy(snapshot = snapshot) }
	}

	private fun updatePools() {
		val now = System.currentTimeMillis() / 1000
		val pools =
			announcements.values
				.filter {
					val t = it.getJSONObject("terms")
					val outputs = t.optInt("outputs", 1)
					now - it.getLong("created_at") <= 2100 &&
						t.optInt("v") >= 3 &&
						t.optString("script") == "p2wpkh" &&
						t.optString("state") == "open" &&
						t.optLong("timeout") > now &&
						t.optInt("peers") < t.optInt("max_peers") &&
						outputs in 1..5 &&
						Math.multiplyExact(t.getLong("denomination"), outputs.toLong()) >= 10000
				}
				.sortedBy { it.getJSONObject("terms").getLong("timeout") }
		change { it.copy(pools = pools) }
	}

	private fun flush() {
		if (!mutable.value.connected) return
		val now = System.currentTimeMillis()
		for (r in rows("rounds")) {
			if (r.optString("relay") != relay || r.optBoolean("tor") != useTor) continue
			val out = r.getJSONArray("outbox")
			for (i in 0 until out.length()) {
				val item = out.getJSONObject(i)
				val event = item.getJSONObject("event")
				val id = event.getString("id")
				if (now - (attempts[id] ?: 0) < 30000) continue
				attempts[id] = now
				if (item.optBoolean("isolated")) {
					outputs.remove(id)?.cancel()
					outputs[id] = open(generation, event)
				} else send(socket, JSONArray().put("EVENT").put(event))
			}
		}
	}

	fun stop() {
		generation++
		ticker?.cancel()
		socket?.cancel()
		socket = null
		outputs.values.forEach { it.cancel() }
		outputs.clear()
		attempts.clear()
		subscribed = ""
		replay.clear()
		replayBytes = 0
		replaying = false
		change { it.copy(connected = false) }
	}
}
