package xyz.paperclip.wallet

import org.json.JSONObject
import java.util.UUID

internal data class JoinBlaketSendDraft(val jar: Int, val destination: String, val amountSat: Long,
	val feeRateMillisatVb: Long, val maxFeeSat: Long,
	val id: String = (UUID.randomUUID().toString() + UUID.randomUUID().toString()).replace("-", ""),
	val coinjoin: Boolean = false) {
	init { validate() }
	fun validate() {
		require(JoinBlaketPayment.validId(id) && jar in 0..4 && destination.matches(Regex("[A-Za-z0-9]{14,90}"))) { "Review the jar and XBT address" }
		require(amountSat in 1..2_100_000_000_000_000L && maxFeeSat > 0 && maxFeeSat <= 2_100_000_000_000_000L - amountSat && feeRateMillisatVb in 1000..10_000_000) { "Review the amount and mining fee limit" }
	}
	fun body(): JSONObject {
		validate()
		return JSONObject().put("id",id).put("purpose","send").put("jar",jar).put("destination",destination)
			.put("amount_sat",amountSat).put("send_max",false).put("fee_rate_millisat_vb",feeRateMillisatVb)
			.put("max_fee_sat",maxFeeSat).put("max_total_sat",amountSat+maxFeeSat).put("rbf",!coinjoin).put("coinjoin",coinjoin)
	}
}

internal data class JoinBlaketSendReview(val payment: JoinBlaketPayment, val approval: String,
	val walletIdentity: String, val network: String, val expires: Long) {
	companion object {
		fun parse(value: JSONObject, wallet: String): JoinBlaketSendReview {
			val q = value.getJSONObject("quote"); val expires = value.get("expires")
			require((expires is Int || expires is Long) && q.get("rbf") == (q.opt("coinjoin") != true)) { "Invalid Jam payment review" }
			return JoinBlaketSendReview(JoinBlaketPayment.parse(value,wallet),value.getString("approval"),q.getString("wallet_identity"),q.getString("network"),(expires as Number).toLong())
		}
	}
	fun validate(draft: JoinBlaketSendDraft, wallet: String, identity: String, now: Long = java.time.Instant.now().epochSecond) {
		draft.validate()
		val q = checkNotNull(payment.quote)
		require(payment.id == draft.id && payment.state == "prepared" && JoinBlaketPayment.validId(approval) && expires > now && expires <= now+300 &&
			walletIdentity == identity && network in setOf("xbt-mainnet","xbt-testnet","xbt-signet","xbt-regtest") &&
			identity.startsWith("$network:") && JoinBlaketPayment.validId(identity.removePrefix("$network:")) &&
			q.wallet == wallet && q.purpose == "send" && q.jar == draft.jar && q.destination == draft.destination && q.coinjoin == draft.coinjoin && q.amountSat == draft.amountSat && q.feeSat <= draft.maxFeeSat) { "Jam review changed or expired. Check payment activity before another action." }
	}
}

private suspend fun JoinBlaketClient.sendIdentity(auth: JoinBlaketAuthorization): String {
	val value = request(listOf("wallet",auth.wallet,"paperclip","identity"),auth)
	require(value.getString("wallet") == auth.wallet) { "Jam wallet changed" }
	return value.getString("identity").also {
		val parts = it.split(':')
		require(parts.size == 2 && parts[0] in setOf("xbt-mainnet","xbt-testnet","xbt-signet","xbt-regtest") && JoinBlaketPayment.validId(parts[1])) { "Invalid Jam wallet identity" }
	}
}

internal suspend fun JoinBlaketClient.prepareSend(draft: JoinBlaketSendDraft, auth: JoinBlaketAuthorization): JoinBlaketSendReview {
	require(canDiscardReviews) { "This pairing permits management only" }
	draft.validate()
	val identity = sendIdentity(auth)
	val features = request(listOf("paperclip","capabilities"),auth)
	require(features.get("version") in listOf(1,2) && features.get("reviewed_direct_send") == true &&
		(!draft.coinjoin || (features.get("version") == 2 && features.opt("coinjoin_payments") == true))) { "Update the Jam companion before sending" }
	val review = JoinBlaketSendReview.parse(request(listOf("wallet",auth.wallet,"paperclip","payments"),auth,draft.body(),preparingCoinJoin=draft.coinjoin),auth.wallet)
	review.validate(draft,auth.wallet,identity)
	return review
}

internal suspend fun JoinBlaketClient.commitSend(review: JoinBlaketSendReview, draft: JoinBlaketSendDraft, auth: JoinBlaketAuthorization): JoinBlaketPayment {
	require(canDiscardReviews) { "This pairing permits management only" }
	review.validate(draft,auth.wallet,review.walletIdentity)
	val identity = sendIdentity(auth)
	require(identity == review.walletIdentity) { "Jam wallet changed since review" }
	val path = listOf("wallet",auth.wallet,"paperclip","payments",draft.id)
	val saved = request(if (isPaired) path + "review" else path,auth)
	val current = JoinBlaketPayment.parse(saved,auth.wallet)
	require(current.id == draft.id && current.quote == review.payment.quote) { "Jam payment changed" }
	if (current.needsCheck || current.state == "submitted") return current
	val checked = JoinBlaketSendReview.parse(saved,auth.wallet)
	checked.validate(draft,auth.wallet,identity)
	require(checked.approval == review.approval) { "Jam approval changed" }
	val result = JoinBlaketPayment.parse(request(path + "commit",auth,JSONObject().put("approval",review.approval),walletIdentity=review.walletIdentity),auth.wallet)
	require(result.id == draft.id && result.quote == review.payment.quote && (result.needsCheck || result.state == "submitted")) { "Check Jars payment activity before another action" }
	return result
}
