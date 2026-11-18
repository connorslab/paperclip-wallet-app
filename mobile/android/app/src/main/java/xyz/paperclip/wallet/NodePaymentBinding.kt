package xyz.paperclip.wallet

import org.json.JSONObject

/** Recovery metadata only: assigning an older record never authorizes a send. */
internal object NodePaymentBinding {
	fun needsReview(record: JSONObject) = record.isNull("endpoint") && record.isNull("implementation")

	fun requireMatches(record: JSONObject, connection: NodeConnection) {
		check(!needsReview(record)) { "Confirm the original node in Payment status before checking this older payment" }
		check(record.opt("endpoint") == connection.endpoint && record.opt("implementation") == connection.implementation) {
			"Reconnect the original node to check this payment"
		}
	}

	fun assign(record: JSONObject, connection: NodeConnection): JSONObject {
		check(needsReview(record)) { "This payment already belongs to a node; its binding cannot be replaced" }
		val hash = record.opt("hash") as? String
		val invoice = record.opt("invoice") as? String
		require(hash != null && hash.matches(Regex("[a-fA-F0-9]{64}")) &&
			invoice != null && invoice.isNotEmpty() && invoice.toByteArray().size <= 16384) { "Saved payment needs recovery" }
		connection.validate()
		return JSONObject(record.toString()).put("endpoint", connection.endpoint).put("implementation", connection.implementation)
	}

	fun assignReviewed(record: JSONObject, reviewed: String, connection: NodeConnection, reviewedConnection: NodeConnection): JSONObject {
		requireCurrent(record, reviewed, connection, reviewedConnection)
		return assign(record, connection)
	}

	fun requireCurrent(record: JSONObject?, expected: String, connection: NodeConnection?, expectedConnection: NodeConnection) {
		check(record?.toString() == expected && connection == expectedConnection) {
			"The saved payment or node connection changed. Reopen Payment status before checking again"
		}
	}
}
