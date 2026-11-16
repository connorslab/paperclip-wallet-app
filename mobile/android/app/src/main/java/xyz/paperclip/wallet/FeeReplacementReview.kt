package xyz.paperclip.wallet

import org.json.JSONObject

internal object FeeReplacementReview {
    fun validate(data: JSONObject, expectedTransaction: String) {
        try {
            fun number(value: JSONObject, key: String): Long {
                val raw = value.get(key)
                require(raw is Int || raw is Long)
                return (raw as Number).toLong().also { require(it >= 0) }
            }
            val original = data.getString("original_txid")
            val replacement = data.getString("replacement_txid")
            require(original.matches(Regex("[0-9a-f]{64}")) && replacement.matches(Regex("[0-9a-f]{64}")))
            require(original == expectedTransaction && replacement != original)
            val old = number(data, "old_fee_sat"); val next = number(data, "new_fee_sat")
            require(next > old && next <= 1_000_000 && number(data, "additional_fee_sat") == next - old)
            val recipients = data.getJSONArray("recipients"); require(recipients.length() > 0)
            for(i in 0 until recipients.length()) {
                val row = recipients.getJSONObject(i)
                require(row.getString("address").length in 1..128 && number(row, "amount_sat") in 1..2_100_000_000_000_000L)
            }
        } catch (_: Exception) { throw IllegalArgumentException("The fee review is incomplete. No replacement was submitted.") }
    }
}
