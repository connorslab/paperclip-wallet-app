package xyz.paperclip.wallet

import android.content.Context
import java.io.IOException
import java.net.URI
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject

internal data class JoinBlaketConnection(
	val endpoint: String,
	val pin: String = "",
	val proxy: String = "",
) {
	fun validate() {
		val uri = URI(endpoint)
		require(uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank() &&
			uri.port in -1..65535 && uri.port != 0 && uri.rawUserInfo == null &&
			uri.rawQuery == null && uri.rawFragment == null) { "Enter the Jam server address without credentials" }
		val onion = uri.host.lowercase().endsWith(".onion")
		require(uri.scheme == "https" || (onion && proxy.isNotBlank() && pin.isEmpty())) {
			"Use HTTPS, or an onion service through Tor"
		}
		require(!onion || proxy.isNotBlank()) { "Onion servers require Tor" }
		val pins = pin.split(',').map(String::trim)
		require(pin.isEmpty() || (pins.size in 1..4 && pins.all { it.matches(Regex("[0-9a-fA-F]{64}")) })) { "Enter up to four SHA256 certificate fingerprints" }
		if (proxy.isNotEmpty() && proxy != "builtin") {
			val p = URI(proxy)
			require(p.scheme == "socks5h" && p.host != null && p.port in 1..65535 &&
				p.rawUserInfo == null && p.rawQuery == null && p.rawFragment == null &&
				p.rawPath.isNullOrEmpty() && !p.host.endsWith(".onion")) { "Use socks5h://host:port" }
		}
	}
}

// Not a data class: never include the token in generated toString or copy output.
internal class JoinBlaketAuthorization(val wallet: String, internal val token: String) {
	init {
		require(wallet.isNotEmpty() && wallet.toByteArray().size <= 256)
		require(token.isNotEmpty() && token.length < 16384 && token.all { it.code in 33..126 })
	}
	override fun toString() = "JoinBlaket authorization (redacted)"
}

/** Independent remote wallet; no Paperclip seed is sent to Jam. No request is replayed. */
internal class JoinBlaketClient internal constructor(
	private val connection: JoinBlaketConnection,
	private val client: OkHttpClient,
) {
	companion object {
		suspend fun open(context: Context, connection: JoinBlaketConnection): JoinBlaketClient {
			connection.validate()
			val route = if (connection.proxy == "builtin") EmbeddedTor.proxy(context) else connection.proxy
			return JoinBlaketClient(connection, NodeHTTPTransport.create(connection.endpoint, connection.pin, route))
		}
	}

	private suspend fun request(
		components: List<String>, authorization: JoinBlaketAuthorization? = null, body: JSONObject? = null,
	): JSONObject {
		connection.validate()
		val url = connection.endpoint.toHttpUrl().newBuilder()
		for (part in listOf("api", "v1") + components) {
			require(part.isNotEmpty() && '/' !in part && '\\' !in part && part !in setOf(".", "..")) { "Invalid Jam wallet path" }
			url.addPathSegment(part)
		}
		val request = Request.Builder().url(url.build()).header("Accept", "application/json")
		authorization?.let { request.header("Authorization", "Bearer " + it.token) }
		body?.let { request.post(it.toString().toRequestBody("application/json".toMediaType())) }
		val call = client.newCall(request.build())
		return suspendCancellableCoroutine { continuation ->
			continuation.invokeOnCancellation { call.cancel() }
			call.enqueue(object : Callback {
				override fun onFailure(call: Call, e: IOException) { continuation.resumeWithException(e) }
				override fun onResponse(call: Call, response: Response) {
					try {
						val result = response.use {
							require(it.code != 401) { "Unlock your JoinBlaket wallet again to continue" }
							require(it.isSuccessful) { "JoinBlaket request failed (HTTP ${it.code}). Check its current status before retrying an action." }
							val source = it.body?.source() ?: error("Empty JoinBlaket response")
							require(!source.request(4L * 1024 * 1024 + 1)) { "JoinBlaket response too large" }
							JSONObject(source.readUtf8())
						}
						continuation.resume(result)
					} catch (e: Exception) { continuation.resumeWithException(e) }
				}
			})
		}
	}

	suspend fun wallets(): List<String> {
		val values = request(listOf("wallet", "all")).getJSONArray("wallets")
		return (0 until values.length()).map { values.getString(it) }
	}
	suspend fun unlock(wallet: String, password: String, passphrase: String = ""): JoinBlaketAuthorization {
		val body = JSONObject().put("password", password)
		if (passphrase.isNotEmpty()) body.put("bip39_passphrase", passphrase)
		val response = request(listOf("wallet", wallet, "unlock"), body = body)
		require(response.getString("walletname") == wallet) { "The active JoinBlaket wallet changed. Reconnect before continuing." }
		return JoinBlaketAuthorization(wallet, response.getString("token"))
	}
	suspend fun status(authorization: JoinBlaketAuthorization): JSONObject {
		val result = request(listOf("session"), authorization)
		require(result.getBoolean("session") && result.getString("wallet_name") == authorization.wallet) {
			"The active JoinBlaket wallet changed. Reconnect before continuing."
		}
		return result
	}
	/** Normalize with the shared Rust jar validator before displaying balances. */
	suspend fun coins(authorization: JoinBlaketAuthorization): JSONObject {
		status(authorization)
		return request(listOf("wallet", authorization.wallet, "utxos"), authorization)
	}
	suspend fun receiveAddress(jar: Int, authorization: JoinBlaketAuthorization): String {
		require(jar in 0..4) { "Unknown JoinBlaket jar" }
		return request(listOf("wallet", authorization.wallet, "address", "new", jar.toString()), authorization).getString("address")
	}
	suspend fun startMaker(minimumSat: Long, feeSat: Long, authorization: JoinBlaketAuthorization) {
		require(minimumSat in 27_300..2_100_000_000_000_000L && feeSat in 0 until minimumSat) { "Review the maker amount and fee" }
		val current = status(authorization)
		require(!current.getBoolean("maker_running") && !current.getBoolean("coinjoin_in_process") && !current.getBoolean("rescanning")) { "Wait for the current Jam operation to finish" }
		request(listOf("wallet", authorization.wallet, "maker", "start"), authorization,
			JSONObject().put("txfee", "0").put("cjfee_a", feeSat.toString()).put("cjfee_r", "0")
				.put("ordertype", "sw0absoffer").put("minsize", minimumSat.toString()))
	}
	suspend fun stopMaker(authorization: JoinBlaketAuthorization) {
		request(listOf("wallet", authorization.wallet, "maker", "stop"), authorization)
	}
}
