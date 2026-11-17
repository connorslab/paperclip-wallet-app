package xyz.paperclip.wallet

import org.json.JSONObject

internal object JoinBlaketMakerFee {
	val fixed = listOf(0L, 100L, 200L, 500L, 1000L, 2000L, 5000L, 10000L)
	val rates = listOf("0.00002", "0.00005", "0.0001", "0.0002", "0.0005", "0.001", "0.002", "0.005", "0.01", "0.02", "0.05", "0.1")
	val percentages = listOf("0.002", "0.005", "0.01", "0.02", "0.05", "0.1", "0.2", "0.5", "1", "2", "5", "10")
	val perMillion = listOf(20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000)
	fun label(rate: String) = rates.indexOf(rate).takeIf { it >= 0 }?.let { percentages[it] + "%" } ?: "Unsupported fee"
	fun example(rate: String) = rates.indexOf(rate).takeIf { it >= 0 }?.let { "At 1,000,000 sats, your fee is ${perMillion[it]} sats." } ?: "Choose a supported fee."
}

/** Setup guidance; the daemon still validates the offer and bond. */
internal data class JoinBlaketMakerReadiness(
	val terms: Boolean, val funds: Boolean, val bond: Boolean, val server: Boolean, val fresh: Boolean,
) {
	val canStart: Boolean get() = terms && funds && bond && server && fresh
	val completedChecks: Int get() = listOf(terms,funds,bond,server,fresh).count { it }
	val nextStep: String get() = when {
		!fresh -> "Refresh maker status before continuing."
		!terms -> "Review the minimum amount and fee."
		!server -> "Wait for Jam to finish its current operation."
		!funds -> "Fund a jar and wait for confirmation."
		!bond -> "Set up and fund a fidelity bond."
		else -> "Ready to review. Your server checks final eligibility."
	}
	companion object {
		fun evaluate(minimum: String, fee: String, jars: List<JSONObject>, session: JSONObject?, needsRefresh: Boolean, relativeFee: String? = null): JoinBlaketMakerReadiness {
			fun sats(value: String) = value.takeIf { it.matches(Regex("[0-9]+")) }?.toLongOrNull()
			val min = sats(minimum) ?: 0; val cost = sats(fee)
			val validMinimum = min in 27_300..2_100_000_000_000_000L
			return JoinBlaketMakerReadiness(
				validMinimum && cost != null && cost < min && (if (relativeFee == null) cost in JoinBlaketMakerFee.fixed else relativeFee in JoinBlaketMakerFee.rates && cost == 0L),
				validMinimum && jars.any { it.optLong("confirmed_sat", -1) >= min },
				jars.any { it.optLong("bond_sat", -1) > 0 },
				session?.opt("session") == true && session?.opt("maker_running") == false && session?.opt("rescanning") == false && session?.opt("coinjoin_in_process") == false,
				session != null && !needsRefresh,
			)
		}
	}
}

internal data class JoinBlaketMarket(val amount: Long, val fetched: Long, val updated: Long?, val status: String, val makers: Int, val median: String?) {
	fun summary(now: Long = java.time.Instant.now().epochSecond): String {
		if (status == "stale" || (updated != null && now - updated > 120)) return "Order book is stale. Refresh before comparing fees."
		if (status == "empty") return "No verified bonded offers cover this amount. No median is available."
		if (status != "fresh") return "Order book unavailable. Your selected fee is unchanged."
		return "Median maker fee: $median sats for a $amount-sat CoinJoin · $makers makers."
	}
	companion object {
		fun parse(value: JSONObject, amount: Long, now: Long = java.time.Instant.now().epochSecond): JoinBlaketMarket {
			fun integer(key: String): Long { val n = value.get(key); require(n is Int || n is Long); return (n as Number).toLong() }
			val fetched = integer("fetched_at"); val count = integer("maker_count")
			val updated = if (value.isNull("book_updated_at")) null else integer("book_updated_at")
			val status = value.getString("status"); val median = if (value.isNull("median_fee_sat")) null else value.get("median_fee_sat").also { require(it is String) } as String
			require(integer("amount_sat") == amount && fetched in (now - 120)..(now + 30) && count in 0..10000 && status in setOf("fresh", "stale", "empty", "unavailable"))
			if (status == "fresh") require(count > 0 && updated != null && updated in (now - 120)..(now + 30) && median != null && median.matches(Regex("[0-9]{1,16}(\\.5)?")) && median.toBigDecimal() <= java.math.BigDecimal("2100000000000000"))
			else require(median == null && count == 0L)
			return JoinBlaketMarket(amount, fetched, updated, status, count.toInt(), median)
		}
	}
}
