package xyz.paperclip.wallet

import org.json.JSONObject

/** A receive result belongs to this exact invoice, not merely a reported payment hash. */
internal enum class NodeInvoiceReceipt {
	WAITING, ACCEPTED, PAID, ENDED;

	companion object {
		fun decode(result: JSONObject, lnd: Boolean, invoice: BridgeInvoice): NodeInvoiceReceipt {
			if (lnd) {
				require(hashHex(result.getString("r_hash")) == invoice.hash)
				require(BridgeInvoice(result.getString("payment_request")).text == invoice.text)
				require(nodeAmount(result.get("value_msat")) == invoice.msat)
				return when (result.getString("state")) {
					"OPEN" -> WAITING
					"ACCEPTED" -> ACCEPTED
					"CANCELED" -> ENDED
					"SETTLED" -> {
						require(result.opt("settled") == true && nodeAmount(result.get("amt_paid_msat")) >= invoice.msat)
						PAID
					}
					else -> error("Node invoice status is unavailable")
				}
			}
			val rows = result.getJSONArray("invoices")
			val matches = (0 until rows.length()).map(rows::getJSONObject).filter {
				it.optString("payment_hash").lowercase() == invoice.hash
			}
			require(matches.size == 1) { "The node did not identify this invoice" }
			val row = matches.single()
			require(BridgeInvoice(row.getString("bolt11")).text == invoice.text)
			require(nodeAmount(row.get("amount_msat")) == invoice.msat)
			return when (row.getString("status")) {
				"unpaid" -> WAITING
				"expired" -> ENDED
				"paid" -> {
					require(nodeAmount(row.get("amount_received_msat")) >= invoice.msat)
					PAID
				}
				else -> error("Node invoice status is unavailable")
			}
		}
	}
}
