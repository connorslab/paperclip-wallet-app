package xyz.paperclip.wallet

import java.time.Instant
import org.json.JSONObject

data class WalletActivity(
	val id: String,
	val kind: String,
	val status: String,
	val amount: Long,
	val time: Long?,
	val ark: Boolean,
) {
	companion object {
		fun parse(json: JSONObject): List<WalletActivity> {
			val result = mutableListOf<WalletActivity>()
			val chain = json.getJSONArray("onchain")
			for (i in 0 until chain.length()) {
				val row = chain.getJSONObject(i)
				val id = row.getString("txid")
				require(id.matches(Regex("[0-9a-fA-F]{64}")))
				result +=
					WalletActivity(
						id,
						"On-chain",
						if (row.getBoolean("confirmed")) "confirmed" else "pending",
						row.getLong("change_sat"),
						row.optLong("timestamp")
							.takeIf { it > 0 }
							?.let { Math.multiplyExact(it, 1000) },
						false,
					)
			}
			val movements = json.getJSONArray("movements")
			for (i in 0 until movements.length()) {
				val row = movements.getJSONObject(i)
				val date = row.optJSONObject("time")?.optString("created_at")
				result +=
					WalletActivity(
						"ark-${row.get("id")}",
						row.optJSONObject("subsystem")?.optString("kind")?.replace('_', ' ')
							?: "Ark payment",
						row.getString("status").lowercase(),
						row.getLong("effective_balance"),
						runCatching { Instant.parse(date).toEpochMilli() }.getOrNull(),
						true,
					)
			}
			return result.sortedWith(
				compareByDescending<WalletActivity> { it.time ?: 0 }.thenBy { it.id },
			)
		}
	}
}

internal class ActivityBaseline(private val value: JSONObject = JSONObject()) {
	fun changes(items: List<WalletActivity>, now: Long): List<WalletActivity> {
		val observed = value.optJSONObject("observed") ?: JSONObject()
		val initialized = value.optBoolean("initialized")
		val baseline = value.optLong("baseline", now)
		val changes = items.filter { item ->
			initialized &&
				item.amount != 0L &&
				observed.optString(item.id) != item.status &&
				(observed.has(item.id) || item.time == null || item.time >= baseline)
		}
		for (item in items) observed.put(item.id, item.status)
		value.put("observed", observed).put("initialized", true)
		if (!initialized) value.put("baseline", now)
		return changes
	}

	fun json() = value
}
