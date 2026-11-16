package xyz.paperclip.wallet

import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.Base64
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody

/** Explicit one-shot harness. No run, failed outcome or unknown outcome is replayed. */
class NodeLivePaymentTest {
	@Test fun reconcileSavedArkAttemptWithoutSending() = runBlocking {
		assumeTrue(System.getenv("PAPERCLIP_LIVE_RECONCILE_ARK") == "yes")
		val ledger = JSONObject(File(checkNotNull(System.getenv("PAPERCLIP_LIVE_PAYMENT_LEDGER"))).readText())
		val attempts = ledger.getJSONArray("tests")
		val saved = (0 until attempts.length()).map { attempts.getJSONObject(it) }.last {
			it.optString("case") == "cln_to_ark" && it.has("payment_hash")
		}
		val hash = saved.getString("payment_hash")
		require(hash.matches(Regex("[0-9a-f]{64}")))
		val configuration = JSONObject(File(checkNotNull(System.getenv("PAPERCLIP_LIVE_CONFIG"))).readText())
		val cases = configuration.getJSONArray("cases")
		val fixture = (0 until cases.length()).map { cases.getJSONObject(it) }.first {
			it.getJSONObject("connection").getString("implementation") == "cln" && !it.getJSONObject("connection").getBoolean("useTor")
		}
		val c = fixture.getJSONObject("connection")
		val connection = NodeConnection("cln", c.getString("endpoint"), c.getString("credential"), c.getString("certificateSHA256"), "")
		val node = LightningNode(connection, LightningNode.transport(connection, ""))
		val info = node.info()
		require(info.getString("id") == fixture.getString("expectedIdentity")) { "Authenticated sender identity mismatch" }
		NodeNetwork.decode(info, false)
		val pays = node.track(hash).getJSONArray("pays")
		val statuses = (0 until pays.length()).map { index ->
			val payment = pays.getJSONObject(index)
			require(payment.getString("payment_hash") == hash) { "Sender returned a different payment" }
			payment.getString("status").takeIf { it in setOf("pending", "complete", "failed") } ?: "unrecognized"
		}.distinct().sorted()
		val receipt = try { ArkLiveReceiver(configuration.getJSONObject("ark")).request("lightning/receives/$hash") }
		catch (failure: ArkReceiverHTTPError) { if (failure.status == 404) null else throw failure }
		if (receipt != null) require(receipt.getString("payment_hash") == hash) { "Receiver returned a different payment" }
		val state = receipt?.getString("state")?.takeIf {
			it in setOf("awaiting-payment", "htlcs-ready", "preimage-revealed", "delivering", "settled")
		} ?: if (receipt == null) "unavailable" else "unrecognized"
		// Observation only: never submit, cancel, release the budget reservation,
		// or write a remote response/hash/preimage to the report.
		val report = JSONObject().put("sender_statuses", org.json.JSONArray(statuses))
			.put("receiver_state", state).put("receiver_http_status", if (receipt == null) 404 else 200)
			.put("htlc_vtxo_count", receipt?.optJSONArray("htlc_vtxo_ids")?.length() ?: JSONObject.NULL)
			.put("settled_at_present", receipt?.let { it.has("settled_at") && !it.isNull("settled_at") } ?: JSONObject.NULL)
			.put("payment_submitted", false).put("ledger_changed", false)
		val output = File(checkNotNull(System.getenv("PAPERCLIP_LIVE_RECONCILE_OUTPUT")))
		require(!output.exists()) { "Do not overwrite prior reconciliation evidence" }
		Files.writeString(output.toPath(), report.toString(2), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)
		println("Read-only saved Ark attempt: sender=${statuses.joinToString(",")}, receiver=$state; no payment or ledger change")
	}

	@Test fun diagnoseArkOfferReviewWithoutPayment() = runBlocking {
		assumeTrue(System.getenv("PAPERCLIP_LIVE_REVIEW_ARK") == "yes")
		val configuration = JSONObject(File(checkNotNull(System.getenv("PAPERCLIP_LIVE_CONFIG"))).readText())
		val cases = configuration.getJSONArray("cases")
		val c = (0 until cases.length()).map { cases.getJSONObject(it).getJSONObject("connection") }.first {
			it.getString("implementation") == "cln" && !it.getBoolean("useTor")
		}
		val connection = NodeConnection("cln", c.getString("endpoint"), c.getString("credential"), c.getString("certificateSHA256"), "")
		val node = LightningNode(connection, LightningNode.transport(connection, ""))
		val ark = ArkLiveReceiver(configuration.getJSONObject("ark"))
		val offer = ark.request("lightning/offers").getString("offer")
		try {
			val result = node.review(offer, 10_000, 5)
			require(result.msat == 10_000_000L)
			println("Ark BOLT12 review passed; no payment submitted")
		} catch (failure: Exception) {
			val location = failure.stackTrace.firstOrNull { it.className.startsWith("xyz.paperclip.wallet") }
			println("Review failed: ${failure.javaClass.simpleName} at ${location?.fileName}:${location?.lineNumber}")
			val message = failure.message.orEmpty()
			if (message.startsWith("Node request failed (HTTP ")) println(message)
			throw AssertionError("Ark offer review failed without submitting payment")
		}
	}
	@Test fun authorizedOwnNodeBolt12Payment() = runBlocking {
		val chosen = System.getenv("PAPERCLIP_LIVE_PAYMENT_CASE")
		assumeTrue("Requires explicit payment-test opt-in", chosen?.let { it in setOf("lnd_to_cln", "cln_to_lnd", "cln_to_ark") } == true)
		val ledgerFile = File(checkNotNull(System.getenv("PAPERCLIP_LIVE_PAYMENT_LEDGER")))
		val privateFile = File(checkNotNull(System.getenv("PAPERCLIP_LIVE_CONFIG")))
		val lockFile = File(ledgerFile.parentFile, ledgerFile.name + ".lock")
		FileChannel.open(lockFile.toPath(), StandardOpenOption.CREATE, StandardOpenOption.WRITE).use { channel ->
			channel.lock().use {
				val ledger = JSONObject(ledgerFile.readText())
				val tests = ledger.getJSONArray("tests")
				val previous = (0 until tests.length()).map { tests.getJSONObject(it) }.filter { it.optString("case") == chosen }
				require(previous.isEmpty() || (System.getenv("PAPERCLIP_LIVE_RETRY_PREPARATION") == "yes" &&
					previous.all { it.optString("state") == "failed_before_submission" && !it.has("payment_hash") && it.getLong("reserved_sat") == 0L })) {
					"This case already has an intent; reconcile it instead of resubmitting"
				}
				val amount = if (chosen == "cln_to_ark") 10_000L else 100L
				val feeLimit = 5L; val reserved = amount + feeLimit
				require(ledger.getLong("budget_sat") == 25_000L && ledger.getLong("reserved_or_spent_sat") + reserved <= 25_000L) { "Test budget exhausted" }
				val sender = chosen!!.substringBefore("_to_"); val receiver = chosen.substringAfter("_to_")
				val configuration = JSONObject(privateFile.readText())
				val cases = configuration.getJSONArray("cases")
				val identities = (0 until cases.length()).map { cases.getJSONObject(it) }.associate {
					it.getJSONObject("connection").getString("implementation") to it.getString("expectedIdentity")
				}
				fun node(implementation: String): LightningNode {
					val fixture = (0 until cases.length()).map { cases.getJSONObject(it) }.first {
						it.getJSONObject("connection").getString("implementation") == implementation && !it.getJSONObject("connection").getBoolean("useTor")
					}
					require(fixture.getString("expectedIdentity") == identities[implementation]) { "Unexpected recipient identity" }
					val j = fixture.getJSONObject("connection")
					val c = NodeConnection(implementation, j.getString("endpoint"), j.getString("credential"), j.getString("certificateSHA256"), "")
					return LightningNode(c, LightningNode.transport(c, ""))
				}
				val payer = node(sender)
				val recipient = if (receiver == "ark") null else node(receiver)
				val ark = if (receiver == "ark") ArkLiveReceiver(configuration.getJSONObject("ark")) else null
				for ((kind, node) in listOfNotNull(sender to payer, recipient?.let { receiver to it })) {
					val info = node.info()
					require(info.getString(if (kind == "lnd") "identity_pubkey" else "id") == identities[kind]) { "Authenticated node identity mismatch" }
					NodeNetwork.decode(info, kind == "lnd")
				}
				require(payer.balance().sendable >= reserved * 1000) { "Sender lacks spendable channel balance for this bounded test" }
				if (recipient != null) require(recipient.balance().receivable >= amount * 1000) { "Recipient lacks channel capacity for this bounded test" }
				if (ark != null) {
					val identity = ark.request("wallet/identity")
					require(identity.getString("network") == "bitcoin" && identity.getInt("exit_profile") == 2 && identity.getBoolean("lightning_enabled"))
					val quote = ark.request("fees/lightning/receive?amount_sat=$amount")
					require(quote.getLong("gross_amount_sat") == amount && quote.getLong("net_amount_sat") > 0 &&
						quote.getLong("fee_sat") + quote.getLong("net_amount_sat") == amount) { "Ark receive quote exceeds this test's gross amount" }
				}
				val record = JSONObject().put("case", chosen).put("amount_sat", amount).put("maximum_fee_sat", feeLimit)
					.put("reserved_sat", reserved).put("attempt", previous.size + 1).put("state", "preparing").put("platform", "Android Kotlin adapter on native Mac JVM")
				tests.put(record); ledger.put("reserved_or_spent_sat", ledger.getLong("reserved_or_spent_sat") + reserved)
				fun save() {
					val temporary = File(ledgerFile.parentFile, ledgerFile.name + ".tmp")
					FileOutputStream(temporary).use { output -> output.write(ledger.toString(2).toByteArray()); output.fd.sync() }
					Files.move(temporary.toPath(), ledgerFile.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
				}
				save()
				try {
					val offer = if (ark == null) checkNotNull(recipient).offer(amount, "Paperclip own-node BOLT12 verification")
					else ark.testOffer(amount)
					val review = payer.review(offer, amount, feeLimit)
					require(review.msat == amount * 1000 && review.invoice.startsWith("lni1"))
					record.put("payment_hash", review.hash).put("state", "submitted"); save()
					val result = payer.pay(review)
					if (sender == "lnd") require(result.getString("status") == "SUCCEEDED")
					else {
						require(result.getString("status") == "complete" && result.getString("payment_hash") == review.hash)
						val preimageHex = result.getString("payment_preimage")
						require(preimageHex.matches(Regex("[0-9a-fA-F]{64}")))
						val preimage = preimageHex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
						try { require(MessageDigest.getInstance("SHA-256").digest(preimage).joinToString("") { "%02x".format(it) } == review.hash) }
						finally { preimage.fill(0) }
					}
					record.put("state", "sender_proof_verified"); save()
					var settled = false
					for (attempt in 0 until 6) {
						if (ark != null) {
							val receipt = ark.request("lightning/receives/" + review.hash)
							settled = receipt.getString("payment_hash") == review.hash && receipt.getString("state") == "settled"
						} else if (receiver == "lnd") {
							val invoice = checkNotNull(recipient).request("v1/invoice/" + review.hash)
							val hash = Base64.getDecoder().decode(invoice.getString("r_hash")).joinToString("") { "%02x".format(it) }
							settled = hash == review.hash && invoice.optString("state") == "SETTLED" && nodeAmount(invoice.get("amt_paid_msat")) >= review.msat
						} else {
							val rows = checkNotNull(recipient).request("v1/listinvoices", JSONObject().put("payment_hash", review.hash)).getJSONArray("invoices")
							settled = (0 until rows.length()).map { rows.getJSONObject(it) }.any {
								it.optString("payment_hash") == review.hash && it.optString("status") == "paid" && nodeAmount(it.get("amount_received_msat")) >= review.msat
							}
						}
						if (settled) break
						delay(2000)
					}
					require(settled) { "Recipient settlement was not verified; do not retry the payment" }
					record.put("state", "settled_both_sides"); save()
					println("Verified $chosen BOLT12: $amount sats, sender proof and receiver settlement; reserved at most $reserved sats")
				} catch (failure: Exception) {
					if (record.getString("state") == "preparing" && !record.has("payment_hash")) {
						record.put("state", "failed_before_submission").put("reserved_sat", 0)
						ledger.put("reserved_or_spent_sat", ledger.getLong("reserved_or_spent_sat") - reserved)
					}
					val location = failure.stackTrace.firstOrNull { it.className.startsWith("xyz.paperclip.wallet") }
					record.put("failure_location", "${location?.fileName}:${location?.lineNumber}")
					record.put("failure_type", failure.javaClass.simpleName); save()
					// Never include a remote payload, token, preimage or invoice in test output.
					throw AssertionError("Live payment check stopped at ${record.getString("state")}; reconcile the saved intent before any retry")
				}
			}
		}
	}
}

private class ArkReceiverHTTPError(val status: Int) : IllegalArgumentException("Ark receiver request failed (HTTP $status)")

/** Only the user's existing Ark receiver, using the supplied trusted StartOS CA. */
private class ArkLiveReceiver(private val config: JSONObject) {
	private val client: OkHttpClient
	init {
		val ca = File(checkNotNull(System.getenv("PAPERCLIP_LIVE_CA_FILE")))
		val certificate = ca.inputStream().use { CertificateFactory.getInstance("X.509").generateCertificate(it) }
		val roots = KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null, null); setCertificateEntry("startos", certificate) }
		val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(roots) }
		val trust = factory.trustManagers.filterIsInstance<X509TrustManager>().single()
		val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
		client = OkHttpClient.Builder().sslSocketFactory(tls.socketFactory, trust).followRedirects(false).followSslRedirects(false)
			.retryOnConnectionFailure(false).callTimeout(60, TimeUnit.SECONDS).build()
		require(config.getString("endpoint").startsWith("https://"))
	}
	fun request(path: String, body: JSONObject? = null): JSONObject {
		return checkNotNull(nullableRequest(path, body)) { "Expected Ark response" }
	}
	fun testOffer(amount: Long): String {
		val existing = nullableRequest("lightning/offers", null)
		if (existing != null) {
			require(existing.getBoolean("active") && (existing.isNull("amount_sat") || existing.getLong("amount_sat") == amount)) { "Existing Ark offer must not be replaced for a test" }
			return existing.getString("offer")
		}
		return request("lightning/offers", JSONObject().put("description", "Paperclip own-wallet BOLT12 verification").put("amount_sat", amount)).getString("offer")
	}
	private fun nullableRequest(path: String, body: JSONObject?): JSONObject? {
		require(body == null || path == "lightning/offers") { "Ark harness can only create an offer; it cannot send funds" }
		val request = Request.Builder().url(config.getString("endpoint").trimEnd('/') + "/api/v1/" + path)
			.header("Authorization", "Bearer " + config.getString("apiToken"))
		body?.let { request.post(it.toString().toRequestBody("application/json".toMediaType())) }
		return client.newCall(request.build()).execute().use {
			if (!it.isSuccessful) throw ArkReceiverHTTPError(it.code)
			val source = checkNotNull(it.body).source(); require(!source.request(4L * 1024 * 1024 + 1))
			val text = source.readUtf8()
			if (text.trim() == "null") null else JSONObject(text)
		}
	}
}
