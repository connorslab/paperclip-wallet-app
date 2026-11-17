package xyz.paperclip.wallet

import org.json.JSONObject

internal object PendingPaymentRecovery {
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
