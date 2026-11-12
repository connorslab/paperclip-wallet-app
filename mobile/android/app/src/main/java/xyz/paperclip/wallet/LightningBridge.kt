package xyz.paperclip.wallet

import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

internal class BridgeQuote(val value: JSONObject) {
	fun validate(
		target: BridgeInvoice,
		receiveXbt: Boolean,
		now: Long = System.currentTimeMillis() / 1000,
	): BridgeInvoice {
		val hold = BridgeInvoice(value.getString("hold_invoice"))
		val sat = value.getDouble("sat")
		val pay = nodeAmount(value.get("pay_sat"))
		val rate = value.getDouble("rate")
		val spread = value.getDouble("spread")
		val token = value.getString("token")
		val expiry = nodeAmount(value.get("expires_at"))
		require(
			target.xbt == receiveXbt &&
				hold.xbt != receiveXbt &&
				value.getString("hash") == target.hash &&
				hold.hash == target.hash,
		)
		require(
			sat.isFinite() &&
				kotlin.math.abs(sat * 1000 - target.msat) < 0.01 &&
				pay in 1..2100000000000000L &&
				(hold.msat + 999) / 1000 == pay,
		)
		require(
			rate.isFinite() &&
				rate > 0 &&
				spread.isFinite() &&
				spread >= 0 &&
				token.matches(Regex("[0-9a-fA-F]{32}")),
		)
		require(expiry <= hold.expires && expiry <= target.expires && expiry > now + 5) {
			"Bridge quote expired"
		}
		return hold
	}
}

/** Requests contain only the invoice and bridge proof; never wallet/node credentials. */
internal class LightningBridge(private val apiKey: String = "") {
	private val client =
		OkHttpClient.Builder()
			.followRedirects(false)
			.followSslRedirects(false)
			.retryOnConnectionFailure(false)
			.callTimeout(45, TimeUnit.SECONDS)
			.build()
	private val base =
		if (apiKey.isEmpty()) "https://lightning.paperclip-xbt.xyz/bridge/api/"
		else "https://lightning.paperclip-xbt.xyz/bridge/private/v1/"

	private suspend fun request(path: String, body: JSONObject? = null): JSONObject =
		withContext(Dispatchers.IO) {
			val r = Request.Builder().url(base + path)
			if (apiKey.isNotEmpty()) r.header("Authorization", "Bearer $apiKey")
			if (body != null)
				r.post(body.toString().toRequestBody("application/json".toMediaType()))
			client.newCall(r.build()).execute().use { response ->
				require(response.code == 200) { "Bridge unavailable (HTTP ${response.code})" }
				val source = checkNotNull(response.body).source()
				require(!source.request(65537)) { "Bridge response too large" }
				val j = JSONObject(source.readUtf8())
				require(!j.has("error")) {
					"Bridge cannot process this request. Check availability before trying again."
				}
				j
			}
		}

	suspend fun availability(receiveXbt: Boolean) =
		request("info?direction=" + if (receiveXbt) "toBLAKE2b" else "toSHA256")

	suspend fun quote(target: BridgeInvoice, receiveXbt: Boolean): BridgeQuote {
		target.validateTarget(receiveXbt)
		val body =
			JSONObject()
				.put("invoice", target.text)
				.put("direction", if (receiveXbt) "toBLAKE2b" else "toSHA256")
		if (apiKey.isEmpty()) {
			val challenge = request("pow")
			val nonce =
				solve(challenge.getString("challenge"), challenge.getInt("bits"), target.hash)
			body.put(
				"pow",
				JSONObject().put("challenge", challenge.getString("challenge")).put("nonce", nonce),
			)
		}
		return BridgeQuote(request("quote", body)).also { it.validate(target, receiveXbt) }
	}

	suspend fun status(q: BridgeQuote): JSONObject {
		val hash = q.value.getString("hash")
		val token = q.value.getString("token")
		require(hash.matches(Regex("[0-9a-fA-F]{64}")) && token.matches(Regex("[0-9a-fA-F]{32}")))
		return request("swap/$hash?t=$token")
	}

	private suspend fun solve(challenge: String, bits: Int, hash: String) =
		withContext(Dispatchers.Default) {
			require(
				bits in 0..22 &&
					challenge.toByteArray().size <= 200 &&
					hash.matches(Regex("[0-9a-fA-F]{64}")),
			)
			val start = System.nanoTime()
			val digest = MessageDigest.getInstance("SHA-256")
			for (n in 0 until 16777216) {
				if (n % 4096 == 0) {
					currentCoroutineContext().ensureActive()
					require(System.nanoTime() - start < 45000000000) {
						"Bridge verification timed out"
					}
				}
				val nonce = n.toString(36)
				val bytes = digest.digest("$challenge:$hash:$nonce".toByteArray())
				var zeros = 0
				for (b in bytes) {
					val v = b.toInt() and 255
					zeros += Integer.numberOfLeadingZeros(v) - 24
					if (v != 0) break
				}
				if (zeros >= bits) return@withContext nonce
			}
			error("Bridge verification timed out")
		}
}
