package xyz.paperclip.wallet

import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/** Stored as one encrypted AtomicFile so selection and identities commit together. */
internal class WalletRegistry(private val value: JSONObject) {
	init {
		require(value.getInt("version") == 1)
		val ids = entries().map { UUID.fromString(it.getString("id")).toString() }
		require(ids.distinct().size == ids.size)
		require(ids.isEmpty() || value.getString("active") in ids)
	}

	fun entries(): List<JSONObject> {
		val a = value.getJSONArray("wallets")
		return (0 until a.length()).map { a.getJSONObject(it) }
	}

	fun selected(): JSONObject? =
		entries().firstOrNull { it.getString("id") == value.optString("active") }

	fun put(record: JSONObject) {
		UUID.fromString(record.getString("id"))
		val next = entries().filter { it.getString("id") != record.getString("id") } + record
		value.put("wallets", JSONArray(next)).put("active", record.getString("id"))
	}

	fun select(id: String) {
		require(entries().any { it.getString("id") == id })
		value.put("active", id)
	}

	fun rename(id: String, name: String) {
		require(name.isNotBlank() && name.length <= 80)
		entries().first { it.getString("id") == id }.put("name", name.trim())
	}

	fun remove(id: String) {
		require(entries().any { it.getString("id") == id })
		val remaining = entries().filter { it.getString("id") != id }
		value.put("wallets", JSONArray(remaining))
		if (value.optString("active") == id) {
			if (remaining.isEmpty()) value.remove("active")
			else value.put("active", remaining.first().getString("id"))
		}
	}

	fun json() = value

	companion object {
		fun empty() = WalletRegistry(JSONObject().put("version", 1).put("wallets", JSONArray()))

		fun migrate(old: JSONObject?) = empty().apply { if (old != null) put(old) }
	}
}

data class WalletProfile(val id: String, val name: String, val kind: String, val network: String)
