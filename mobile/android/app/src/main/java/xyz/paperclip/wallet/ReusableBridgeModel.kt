package xyz.paperclip.wallet

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.UUID

internal data class ReusableBridgeState(val rows: List<JSONObject> = emptyList(), val loaded: Boolean = false,
	val busy: Boolean = false, val available: Boolean? = null, val message: String = "", val nodeOffer: String = "")

internal class ReusableBridgeModel(app: Application) : AndroidViewModel(app) {
	private val vault = SecureStore(app)
	private val api = LightningBridge()
	private val mutable = MutableStateFlow(ReusableBridgeState())
	val state = mutable.asStateFlow()
	private val account = "bridge-reusable-offers-v1"
	private fun work(block: suspend () -> Unit) {
		if (mutable.value.busy) return
		mutable.value = mutable.value.copy(busy = true, message = "")
		viewModelScope.launch {
			try { block() }
			catch (e: kotlinx.coroutines.CancellationException) { throw e }
			catch (_: Exception) { mutable.value = mutable.value.copy(message = "Request not confirmed. Your saved key and request are preserved. Check status before creating a replacement.") }
			finally { mutable.value = mutable.value.copy(busy = false) }
		}
	}
	fun load() = work {
		if (!mutable.value.loaded) {
			val json = withContext(Dispatchers.IO) { vault.read(account)?.let { bytes -> try { JSONArray(String(bytes)) } finally { bytes.fill(0) } } } ?: JSONArray()
			require(json.length() <= 100)
			val rows = (0 until json.length()).map { json.getJSONObject(it) }
			for (row in rows) {
				require(ReusableOffer.validToken(row.getString("token")) && row.opt("revocation_requested") is Boolean)
				UUID.fromString(row.getString("id"))
				require(row.has("destination") == row.has("xbt"))
				if (row.has("destination")) { require(row.opt("xbt") is Boolean); ReusableOffer.validate(row.getString("destination"), row.getBoolean("xbt"), now = 0) }
				row.optJSONObject("binding")?.let { binding -> ReusableOffer.response(binding); if (row.has("xbt")) require(row.getBoolean("xbt") == (binding.getString("direction") == "toBLAKE2b")) }
			}
			require(rows.map { it.getString("id") }.toSet().size == rows.size && rows.map { it.getString("token") }.toSet().size == rows.size)
			mutable.value = mutable.value.copy(rows = rows, loaded = true)
		}
		val health = try { api.reusableAvailable() } catch (_: Exception) { null }
		mutable.value = mutable.value.copy(available = health)
	}
	fun refreshAvailability() {
		viewModelScope.launch {
			val available = try { api.reusableAvailable() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { null }
			mutable.value = mutable.value.copy(available = available)
		}
	}
	private suspend fun save(row: JSONObject) {
		check(mutable.value.loaded)
		val rows = mutable.value.rows.toMutableList(); val index = rows.indexOfFirst { it.getString("id") == row.getString("id") }
		if (index >= 0) rows[index] = row else { require(rows.size < 100); rows.add(row) }
		withContext(Dispatchers.IO) {
			val bytes = JSONArray(rows).toString().toByteArray(); try { vault.write(account, bytes) } finally { bytes.fill(0) }
		}
		mutable.value = mutable.value.copy(rows = rows)
	}
	fun create(destination: String, xbt: Boolean) = work {
		val input = destination.trim(); ReusableOffer.validate(input, xbt); val text = input.lowercase()
		val existing = mutable.value.rows.firstOrNull { it.optString("destination") == text && it.opt("xbt") == xbt && it.optJSONObject("binding")?.optBoolean("revoked") != true }
		val row = existing ?: JSONObject().put("id", UUID.randomUUID().toString()).put("token", ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) })
			.put("destination", text).put("xbt", xbt).put("revocation_requested", false)
		save(row); update(row, if (row.has("binding")) "lookup" else "register")
	}
	fun restore(key: String) = work {
		val token = key.trim().lowercase(); require(ReusableOffer.validToken(token))
		val row = mutable.value.rows.firstOrNull { it.getString("token") == token } ?: JSONObject().put("id", UUID.randomUUID().toString()).put("token", token).put("revocation_requested", false)
		save(row); update(row, "lookup")
	}
	fun action(row: JSONObject, action: String) = work { update(row, action) }
	private suspend fun update(saved: JSONObject, action: String) {
		val row = JSONObject(mutable.value.rows.first { it.getString("id") == saved.getString("id") }.toString())
		if (action == "revoke") { row.put("revocation_requested", true); save(row) }
		require(action != "register" || !row.optBoolean("revocation_requested"))
		val value = api.reusable(action, row.getString("token"), row.optString("destination").takeIf { it.isNotEmpty() }, row.opt("xbt") as? Boolean)
		if (row.has("xbt")) require(row.getBoolean("xbt") == (value.getString("direction") == "toBLAKE2b"))
		row.optJSONObject("binding")?.let { old -> require(old.getString("offer") == value.getString("offer") && old.getString("direction") == value.getString("direction") && (!old.getBoolean("revoked") || value.getBoolean("revoked"))) }
		row.put("binding", value); save(row)
		mutable.value = mutable.value.copy(message = if (value.getBoolean("revoked")) "Revoked. In-flight payments can still finish or refund." else "Offer saved. Creating an offer does not confirm a payment.")
	}
	fun useNode() = work {
		val bytes = withContext(Dispatchers.IO) { vault.read("lightning-connection") } ?: error("Connect a node first")
		val connection = try { NodeConnection.from(JSONObject(String(bytes))) } finally { bytes.fill(0) }
		val node = LightningNode.open(getApplication(), connection)
		require(NodeNetwork.decode(node.info(), connection.implementation == "lnd") == NodeNetwork.MAINNET)
		val offer = node.offer(null, "Paperclip Bridge")
		val current = withContext(Dispatchers.IO) { vault.read("lightning-connection") } ?: error("Connection changed")
		try { require(NodeConnection.from(JSONObject(String(current))) == connection) } finally { current.fill(0) }
		ReusableOffer.validate(offer, true); mutable.value = mutable.value.copy(nodeOffer = offer)
	}
}
