package xyz.paperclip.wallet

import org.json.JSONObject

/** Setup guidance; the daemon still validates the offer and bond. */
internal data class JoinBlaketMakerReadiness(
	val terms: Boolean, val funds: Boolean, val bond: Boolean, val server: Boolean, val fresh: Boolean,
) {
	val canStart: Boolean get() = terms && funds && bond && server && fresh
	companion object {
		fun evaluate(minimum: String, fee: String, jars: List<JSONObject>, session: JSONObject?, needsRefresh: Boolean): JoinBlaketMakerReadiness {
			fun sats(value: String) = value.takeIf { it.matches(Regex("[0-9]+")) }?.toLongOrNull()
			val min = sats(minimum) ?: 0; val cost = sats(fee)
			val validMinimum = min in 27_300..2_100_000_000_000_000L
			return JoinBlaketMakerReadiness(
				validMinimum && cost != null && cost < min,
				validMinimum && jars.any { it.optLong("confirmed_sat", -1) >= min },
				jars.any { it.optLong("bond_sat", -1) > 0 },
				session?.opt("session") == true && session?.opt("maker_running") == false && session?.opt("rescanning") == false && session?.opt("coinjoin_in_process") == false,
				session != null && !needsRefresh,
			)
		}
	}
}
