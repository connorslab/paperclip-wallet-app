package xyz.paperclip.wallet

import org.json.JSONObject

internal data class JoinBlaketBondCoin(val outpoint: String, val valueSat: Long, val locktime: Long,
	val confirmations: Long, val frozen: Boolean, val signable: Boolean) {
	fun canWithdraw(chainTime: Long) = locktime < chainTime && confirmations > 0 && !frozen && signable
	val unlockDescription: String get() = java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm 'UTC'", java.util.Locale.ROOT).withZone(java.time.ZoneOffset.UTC).format(java.time.Instant.ofEpochSecond(locktime))
	companion object {
		fun validOutpoint(point: String): Boolean {
			val parts = point.split(':')
			return parts.size == 2 && JoinBlaketPayment.validId(parts[0]) && parts[1].toLongOrNull()?.let { it in 0..4294967295L && it.toString() == parts[1] } == true
		}
	}
}
internal data class JoinBlaketBondInventory(val wallet: String, val identity: String, val chainTime: Long, val bonds: List<JoinBlaketBondCoin>) {
	companion object {
		fun parse(value: JSONObject, wallet: String): JoinBlaketBondInventory {
			fun integer(row: JSONObject, key: String): Long { val n = row.get(key); require(n is Int || n is Long); return (n as Number).toLong() }
			val identity = value.getString("identity"); val parts = identity.split(':'); val cutoff = integer(value,"chain_time")
			require(value.getString("wallet") == wallet && parts.size == 2 && parts[0] in setOf("xbt-mainnet","xbt-testnet","xbt-signet","xbt-regtest") && JoinBlaketPayment.validId(parts[1]) && cutoff in 1_577_836_800L..4_294_967_295L)
			val rows = value.getJSONArray("bonds"); require(rows.length() <= 100)
			val seen = mutableSetOf<String>(); var total = 0L
			val bonds = (0 until rows.length()).map {
				val row = rows.getJSONObject(it); val point = row.getString("outpoint"); val amount = integer(row,"value_sat"); val lock = integer(row,"locktime"); val confirmations = integer(row,"confirmations")
				require(JoinBlaketBondCoin.validOutpoint(point) && seen.add(point) && amount in 1..2_100_000_000_000_000L-total && lock in 1_577_836_800L..4_099_766_400L && confirmations in 0..4294967295L && row.get("frozen") is Boolean && row.get("signable") is Boolean)
				total += amount
				JoinBlaketBondCoin(point,amount,lock,confirmations,row.getBoolean("frozen"),row.getBoolean("signable"))
			}
			return JoinBlaketBondInventory(wallet,identity,cutoff,bonds)
		}
	}
}
internal suspend fun JoinBlaketClient.bonds(auth: JoinBlaketAuthorization): JoinBlaketBondInventory {
	status(auth)
	return JoinBlaketBondInventory.parse(request(listOf("wallet",auth.wallet,"paperclip","bonds"),auth),auth.wallet)
}
