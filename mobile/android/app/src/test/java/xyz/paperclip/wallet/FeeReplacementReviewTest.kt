package xyz.paperclip.wallet

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class FeeReplacementReviewTest {
    @Test fun rejectsAlteredOrIncompleteReviews() {
        val id = "a".repeat(64)
        val valid = JSONObject().put("original_txid", id).put("replacement_txid", "b".repeat(64))
            .put("old_fee_sat", 1000).put("new_fee_sat", 2000).put("additional_fee_sat", 1000)
            .put("recipients", JSONArray().put(JSONObject().put("address", "bcrt1qfixture").put("amount_sat", 100000)))
        FeeReplacementReview.validate(valid, id)
        for ((field, value) in listOf("additional_fee_sat" to 999, "new_fee_sat" to 0, "old_fee_sat" to -1, "recipients" to JSONArray(), "original_txid" to "c".repeat(64), "replacement_txid" to id, "new_fee_sat" to 2000.5)) {
            try { FeeReplacementReview.validate(JSONObject(valid.toString()).put(field, value), id); fail("Accepted changed $field") }
            catch (_: IllegalArgumentException) {}
        }
    }
}
