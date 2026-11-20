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

internal data class JoinBlaketOffer(val id: Int, val maker: String, val fee: String, val relative: Boolean,
	val min: Long, val max: Long, val cost: Long, val contribution: Long, val bonded: Boolean) {
	val feeLabel: String get() = if (relative) JoinBlaketMakerFee.label(fee) else "$fee sats"
	fun covers(amount: Long) = amount in min..max
	companion object {
		fun parse(value: JSONObject, amount: Long): JoinBlaketOffer {
			fun number(key: String): Long { val v = value.get(key); require(v is Int || v is Long); return (v as Number).toLong().also { require(it in 0..2_100_000_000_000_000L) } }
			val id = number("id"); val maker = value.get("maker"); val fee = value.get("fee")
			val relative = value.get("relative"); val bonded = value.get("bond_verified")
			require(id < 10000 && maker is String && maker.matches(Regex("[A-Za-z0-9_-]{1,128}")) && fee is String && relative is Boolean && bonded is Boolean)
			val min = number("min_sat"); val max = number("max_sat"); val cost = number("fee_sat"); val contribution = number("mining_contribution_sat")
			require(min <= max)
			val expected = if (relative) {
				require(fee in JoinBlaketMakerFee.rates)
				amount.toBigDecimal().multiply(fee.toBigDecimal()).setScale(0, java.math.RoundingMode.HALF_EVEN).longValueExact()
			} else { require(fee.toLongOrNull() in JoinBlaketMakerFee.fixed && fee.toLong().toString() == fee); fee.toLong() }
			require(cost == expected)
			return JoinBlaketOffer(id.toInt(), maker, fee, relative, min, max, cost, contribution, bonded)
		}
	}
}

internal data class JoinBlaketMarket(val amount: Long, val fetched: Long, val updated: Long?, val status: String, val makers: Int, val median: String?, val offers: List<JoinBlaketOffer>? = null, val excluded: Int = 0) {
	fun visibleOffers(eligibleOnly: Boolean, largestFirst: Boolean): List<JoinBlaketOffer> = (offers ?: emptyList()).filter { !eligibleOnly || (it.bonded && it.covers(amount)) }.sortedWith(compareBy<JoinBlaketOffer> { if (largestFirst) -it.max else 0 }.thenBy { it.cost }.thenBy { it.id })
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
			val offers = if (value.isNull("offers")) null else value.getJSONArray("offers").let { rows ->
				require(rows.length() <= 10000)
				(0 until rows.length()).map { JoinBlaketOffer.parse(rows.getJSONObject(it), amount) }
			}
			val excluded = if (offers == null) 0 else integer("excluded_offer_count").also { require(it in 0..10000) }.toInt()
			if (offers != null) require(offers.map { it.id }.distinct().size == offers.size && offers.size + excluded <= 10000 && (status in setOf("fresh", "empty") || offers.isEmpty()))
			if (!offers.isNullOrEmpty()) require(updated != null && updated in (now - 120)..(now + 30))
			return JoinBlaketMarket(amount, fetched, updated, status, count.toInt(), median, offers, excluded)
		}
	}
}
