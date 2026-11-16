package xyz.paperclip.wallet

import android.content.Context
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ProtocolException
import java.net.Proxy
import java.net.URI
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import javax.net.ssl.X509TrustManager
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject

internal object NodeRequestPolicy {
	fun isReadOnly(path: String): Boolean =
		path.substringBefore('?') in setOf("v1/getinfo", "v1/channels", "v1/listpeerchannels",
			"v1/listpays", "v1/payments", "v1/listinvoices", "v1/decode", "v2/offers/decode") ||
			listOf("v1/invoice/", "v1/payreq/", "v2/router/track/").any(path::startsWith)

	fun canRetry(error: Exception, path: String): Boolean =
		isReadOnly(path) && error is IOException && error !is SSLException && error !is ProtocolException
}

/** Explicit SOCKS route, remote DNS, no redirects, no automatic payment replay. */
internal class LightningNode
internal constructor(val connection: NodeConnection, private val client: OkHttpClient) {
	private val lnd
		get() = connection.implementation == "lnd"

	companion object {
		suspend fun open(context: Context, c: NodeConnection): LightningNode {
			c.validate()
			val route = if (c.proxy == "builtin") EmbeddedTor.proxy(context) else c.proxy
			return LightningNode(c, transport(c, route))
		}

		internal fun transport(c: NodeConnection, route: String): OkHttpClient {
			c.validate()
			require(route != "builtin" && (c.proxy.isEmpty() || route.isNotEmpty())) {
				"Tor is not ready"
			}
			return NodeHTTPTransport.create(c.endpoint, c.pin, route)
		}
	}

	suspend fun request(
		path: String,
		body: JSONObject? = null,
		stream: Boolean = false,
	): JSONObject =
		withContext(Dispatchers.IO) {
			for (attempt in 0..1) {
				currentCoroutineContext().ensureActive()
				try { return@withContext requestOnce(path, body, stream) }
				catch (e: Exception) {
					currentCoroutineContext().ensureActive()
					if (attempt != 0 || !NodeRequestPolicy.canRetry(e, path)) throw e
					delay(500)
				}
			}
			error("Node request failed")
		}

	private suspend fun requestOnce(path: String, body: JSONObject?, stream: Boolean): JSONObject {
			require(!path.startsWith('/') && !path.contains(".."))
			val url = (connection.endpoint.trimEnd('/') + "/" + path).toHttpUrl()
			val r =
				Request.Builder()
					.url(url)
					.header(if (lnd) "Grpc-Metadata-macaroon" else "Rune", connection.credential)
					.header("Accept", "application/json")
			if (body != null)
				r.post(body.toString().toRequestBody("application/json".toMediaType()))
			val call = client.newCall(r.build())
			return suspendCancellableCoroutine { continuation ->
				continuation.invokeOnCancellation { call.cancel() }
				call.enqueue(object : Callback {
					override fun onFailure(call: Call, e: IOException) { continuation.resumeWithException(e) }
					override fun onResponse(call: Call, response: Response) {
						try { continuation.resume(response.use { parseResponse(it, path, stream) }) }
						catch (e: Exception) { continuation.resumeWithException(e) }
					}
				})
			}
	}

	private fun parseResponse(response: Response, path: String, stream: Boolean): JSONObject {
				require(response.code !in 300..399) { "Node redirects are refused" }
				if (response.code == 401) {
					val credential = if (lnd) "LND macaroon" else "Core Lightning rune"
					error("The node rejected the $credential (HTTP 401). Copy a valid credential from this node’s settings and verify again.")
				}
				if (response.code == 403)
					error("This credential does not permit the requested node operation (HTTP 403). Check its permissions in your node settings.")
				if (path.startsWith("v2/offers") && response.code in listOf(404, 501))
					error("This node does not expose XBT LND's BOLT12 offers API")
				if (response.code == 404)
					error("This REST method was not found (HTTP 404). Check the node software, REST address, and port; the dashboard address may be different.")
				require(response.isSuccessful) {
					"Node request failed (HTTP ${response.code}). Payment outcomes must be checked before retrying."
				}
				val source = response.body?.source() ?: error("Empty node response")
				val limit = if (stream) 256L * 1024 else 4L * 1024 * 1024
				val data =
					if (stream) source.readUtf8LineStrict(limit)
					else {
						require(!source.request(limit + 1)) { "Node response too large" }
						source.readUtf8()
					}
				val value = JSONObject(data)
				require(!value.has("error")) {
					"Node RPC failed. Check status before retrying a payment."
				}
				return if (stream) value.getJSONObject("result") else value
	}

	suspend fun info() =
		request(if (lnd) "v1/getinfo" else "v1/getinfo", if (lnd) null else JSONObject())

	suspend fun balance() =
		NodeBalance.decode(
			request(
				if (lnd) "v1/channels" else "v1/listpeerchannels",
				if (lnd) null else JSONObject(),
			),
			lnd,
		)

	suspend fun invoice(sats: Long): String {
		require(sats > 0 && sats <= Long.MAX_VALUE / 1000)
		val j =
			request(
				if (lnd) "v1/invoices" else "v1/invoice",
				if (lnd)
					JSONObject()
						.put("value", sats.toString())
						.put("memo", "Paperclip wallet")
						.put("expiry", "3600")
				else
					JSONObject()
						.put("amount_msat", "${sats*1000}msat")
						.put("description", "Paperclip wallet")
						.put("label", java.util.UUID.randomUUID().toString()),
			)
		return j.getString(if (lnd) "payment_request" else "bolt11")
	}

	suspend fun offer(sats: Long?, description: String): String {
		require(
			description.isNotBlank() &&
				description.toByteArray().size <= 256 &&
				(sats == null || sats in 1..Long.MAX_VALUE / 1000),
		)
		val fields =
			JSONObject()
				.put("description", description)
				.put("label", java.util.UUID.randomUUID().toString())
		if (lnd) fields.put("amount_msat", ((sats ?: 0) * 1000).toString())
		else fields.put("amount", sats?.let { "${it*1000}msat" } ?: "any")
		val response = request(if (lnd) "v2/offers" else "v1/offer", fields)
		val result = if (lnd) response.getJSONObject("offer") else response
		require(result.opt("active") == true)
		return result.getString("bolt12").also { require(it.startsWith("lno1")) }
	}

	suspend fun review(input: String, amountSat: Long?, feeSat: Long): NodeInvoiceReview {
		require(
			input.length <= 256 * 1024 &&
				input.none { it.isWhitespace() } &&
				feeSat >= 0 &&
				feeSat <= Long.MAX_VALUE / 1000,
		)
		val now = System.currentTimeMillis() / 1000
		val network = NodeNetwork.decode(info(), lnd)
		require(network.accepts(input)) {
			"Enter an invoice for this node network or a BOLT12 offer"
		}
		var invoice = input
		var decoded = decode(invoice)
		if (invoice.lowercase().startsWith("lno1")) {
			val offered =
				if (lnd) LndBolt12.offer(decoded, now)
				else {
					require(
						decoded.opt("valid") == true && decoded.optString("type") == "bolt12 offer",
					)
					require(
						listOf("offer_currency", "offer_quantity_max", "offer_recurrence")
							.none(decoded::has),
					) {
						"Currency, quantity and recurring offers are unsupported"
					}
					decoded.opt("offer_absolute_expiry")?.let {
						require(nodeAmount(it) > now) { "Offer expired" }
					}
					decoded.opt("offer_amount_msat")?.let(::nodeAmount)?.also { require(it > 0) }
				}
			val amount =
				amountSat?.let { Math.multiplyExact(it, 1000) }
					?: offered
					?: error("Enter an amount for this offer")
			require(amount > 0 && (offered == null || offered == amount)) {
				"Amount differs from this fixed offer"
			}
			val fields =
				JSONObject()
					.put("offer", invoice)
					.put("amount_msat", if (lnd) amount.toString() else "${amount}msat")
					.put(if (lnd) "timeout_seconds" else "timeout", 30)
			invoice =
				request(if (lnd) "v2/offers/fetchinvoice" else "v1/fetchinvoice", fields)
					.getString(if (lnd) "bolt12" else "invoice")
			require(invoice.lowercase().startsWith("lni1"))
			decoded = decode(invoice)
			val result = invoiceReview(invoice, decoded, feeSat, now)
			require(result.msat == amount) {
				"Fetched invoice amount differs from the offer review"
			}
			return result
		}
		return invoiceReview(invoice, decoded, feeSat, now).also {
			if (amountSat != null)
				require(it.msat == Math.multiplyExact(amountSat, 1000)) {
					"Invoice amount differs from entered amount"
				}
		}
	}

	private suspend fun decode(invoice: String): JSONObject =
		when {
			!lnd -> request("v1/decode", JSONObject().put("string", invoice))
			invoice.lowercase().startsWith("lno1") || invoice.lowercase().startsWith("lni1") ->
				request("v2/offers/decode", JSONObject().put("bolt12", invoice))
			else -> request("v1/payreq/" + invoice)
		}

	private fun invoiceReview(
		invoice: String,
		j: JSONObject,
		fee: Long,
		now: Long,
	): NodeInvoiceReview {
		if (lnd && invoice.lowercase().startsWith("lni1"))
			return LndBolt12.invoice(j, invoice, fee, now)
		if (!lnd)
			require(
				j.opt("valid") == true &&
					j.optString("type") in listOf("bolt11 invoice", "bolt12 invoice"),
			) {
				"Invalid invoice"
			}
		val bolt12 = invoice.lowercase().startsWith("lni1")
		val hash =
			j.getString(if (!lnd && bolt12) "invoice_payment_hash" else "payment_hash").lowercase()
		require(hash.matches(Regex("[0-9a-f]{64}")))
		val amount =
			nodeAmount(
				j.get(
					if (lnd) "num_msat" else if (bolt12) "invoice_amount_msat" else "amount_msat",
				),
			)
		val created =
			nodeAmount(
				j.get(if (lnd) "timestamp" else if (bolt12) "invoice_created_at" else "created_at"),
			)
		val duration =
			nodeAmount(
				if (!lnd && bolt12) j.opt("invoice_relative_expiry") ?: "7200" else j.get("expiry"),
			)
		val expires = Math.addExact(created, duration)
		require(amount > 0 && expires > now) { "Invoice expired or has no amount" }
		return NodeInvoiceReview(invoice, hash, amount, expires, fee)
	}

	// Caller MUST persist an intent before invoking. No caller automatically retries this method.
	suspend fun pay(r: NodeInvoiceReview): JSONObject {
		require(r.valid()) { "Invoice expired. Review again." }
		if (lnd && r.invoice.lowercase().startsWith("lni1")) {
			require(r.feeSat > 0)
			return LndBolt12.result(
				request(
					"v2/offers/pay",
					JSONObject()
						.put("invoice", r.invoice)
						.put("fee_limit_msat", Math.multiplyExact(r.feeSat, 1000).toString())
						.put("timeout_seconds", 30),
				),
				r,
			)
		}
		return if (lnd)
			request(
				"v2/router/send",
				JSONObject()
					.put("payment_request", r.invoice)
					.put("fee_limit_sat", r.feeSat.toString())
					.put("timeout_seconds", 30)
					.put("no_inflight_updates", false)
					.put("cancelable", false),
				stream = true,
			)
		else
			request(
				"v1/pay",
				JSONObject()
					.put("bolt11", r.invoice)
					.put("maxfee", "${Math.multiplyExact(r.feeSat,1000)}msat")
					.put("retry_for", 30),
			)
	}

	suspend fun receivedInvoice(invoice: BridgeInvoice): NodeInvoiceReceipt {
		val result = request(
			if (lnd) "v1/invoice/" + invoice.hash else "v1/listinvoices",
			if (lnd) null else JSONObject().put("payment_hash", invoice.hash),
		)
		return NodeInvoiceReceipt.decode(result, lnd, invoice)
	}

	suspend fun track(hash: String): JSONObject {
		require(hash.matches(Regex("[0-9a-f]{64}")))
		if (!lnd) return request("v1/listpays", JSONObject().put("payment_hash", hash))
		val raw = hash.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
		return request(
			"v2/router/track/" +
				Base64.getUrlEncoder().encodeToString(raw) +
				"?no_inflight_updates=false",
			stream = true,
		)
	}
}
