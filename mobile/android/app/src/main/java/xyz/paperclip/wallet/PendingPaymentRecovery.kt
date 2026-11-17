package xyz.paperclip.wallet

import org.json.JSONObject

internal object PendingPaymentRecovery {
	fun transactionID(result: JSONObject): String? {
		fun transactionID(value: Any?): String? = (value as? String)?.takeIf {
			it.length == 64 && it.all { character -> character in '0'..'9' || character in 'a'..'f' || character in 'A'..'F' }
		}
		val original = transactionID(result.opt("txid"))
		val values = result.optJSONArray("replacement_txids")
		val replacements = (0 until (values?.length() ?: 0)).mapNotNull { transactionID(values?.opt(it)) }
		transactionID(result.opt("confirmed_txid"))?.let { confirmed ->
			return confirmed.takeIf { result.optString("state") == "completed" && (it == original || it in replacements) }
		}
		// A proposed replacement might have lost the race to the original.
		if (result.optString("state") == "completed" && replacements.isNotEmpty()) return null
		return replacements.lastOrNull() ?: original
	}
	fun select(legacy: JSONObject?, native: JSONObject?): JSONObject? {
		// Do not clear an older/independent warning with an unrelated receipt.
		if (legacy != null && PaymentStatus.from(legacy.optString("state")) !in
			listOf(PaymentStatus.COMPLETE, PaymentStatus.NOT_SENT) &&
			(legacy.optString("attempt_id").isEmpty() || legacy.optString("attempt_id") != native?.optString("attempt_id"))) {
			return legacy
		}
		return native ?: legacy
	}
}
