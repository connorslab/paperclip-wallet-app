package xyz.paperclip.wallet

import android.content.Context
import java.io.IOException
import java.net.URI
import java.time.Instant
import java.time.YearMonth
import java.time.ZoneOffset
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

/** Scoped host grant. Persist only through SecureStore; never log the payload. */
internal class JoinBlaketPairing private constructor(val endpoint: String, val wallet: String,
	internal val token: String, private val expires: Long, private val pin: String, val canSend: Boolean) {
	val connection: JoinBlaketConnection get() = JoinBlaketConnection(endpoint, pin, if (URI(endpoint).host.lowercase().endsWith(".onion")) "builtin" else "")
	fun authorization() = JoinBlaketAuthorization(wallet, token)
	override fun toString() = "Jars pairing (redacted)"
	companion object {
		fun parse(text: String, now: Long = Instant.now().epochSecond): JoinBlaketPairing {
			require(text.length <= 4096 && text.startsWith("paperclip-jars:")) { "Scan a Paperclip Jars pairing code" }
			val value = JSONObject(String(java.util.Base64.getUrlDecoder().decode(text.removePrefix("paperclip-jars:")), Charsets.UTF_8))
			val expiry = value.get("expires")
			require(expiry is Int || expiry is Long) { "Invalid pairing expiry" }
			val pair = JoinBlaketPairing(value.getString("endpoint"), value.getString("wallet"), value.getString("token"), (expiry as Number).toLong(), value.getString("certificate_sha256"), value.getString("scope") == "jars_pay_v1")
			require(value.getString("kind") == "paperclip-jars-v1" && value.getString("scope") in setOf("jars_manage_v1", "jars_pay_v1") && pair.expires > now &&
				pair.token.matches(Regex("pj1_[0-9a-f]{64}")) && pair.wallet.isNotEmpty() && pair.wallet.toByteArray().size <= 256 &&
				'/' !in pair.wallet && '\\' !in pair.wallet && pair.wallet !in setOf(".", "..")) { "Pairing is invalid or expired. Create a new code on your host." }
			pair.connection.validate()
			if (pair.connection.proxy == "builtin") require(URI(pair.endpoint).host.lowercase().matches(Regex("[a-z2-7]{56}\\.onion"))) { "Use a full v3 onion address for Tor pairing" }
			return pair
		}
	}
	fun request(parts: List<String>, body: JSONObject?, walletIdentity: String? = null): JSONObject {
		require(expires > Instant.now().epochSecond) { "Pairing expired. Create a new code on your host." }
		val fields = JSONObject().put("wallet", wallet)
		val path = parts.joinToString("/"); val prefix = "wallet/$wallet/"
		when {
			canSend && path == "paperclip/capabilities" && body == null -> fields.put("operation","payment_capabilities")
			canSend && path == prefix + "paperclip/identity" && body == null -> fields.put("operation","identity")
			canSend && path == prefix + "paperclip/payments" && body != null -> {
				val lock = if (body.isNull("bond_locktime")) null else body.get("bond_locktime").also { require(it is Long || it is Int) }.let { (it as Number).toLong() }
				val points = body.optJSONArray("input_utxos")
				val point = points?.let { require(it.length() == 1); it.getString(0) }
				require(body.length() == (if(point != null) 13 else if (lock == null) 11 else 12) && body.get("purpose") == (if(point != null) "withdraw_bond" else if (lock == null) "send" else "fund_bond") && body.get("send_max") == (point != null) && (point == null || body.getLong("amount_sat") == 0L) && body.get("coinjoin") is Boolean && body.get("rbf") == !body.getBoolean("coinjoin"))
				val draft = JoinBlaketSendDraft(body.getInt("jar"),body.getString("destination"),(if(point == null) body.getLong("amount_sat") else body.getLong("max_total_sat")),body.getLong("fee_rate_millisat_vb"),body.getLong("max_fee_sat"),body.getString("id"),body.getBoolean("coinjoin"),lock,point)
				require(body.getLong("max_total_sat") == (if(point == null) draft.amountSat + draft.maxFeeSat else draft.amountSat))
				val terms = JSONObject()
				for (key in listOf("jar","destination","amount_sat","fee_rate_millisat_vb","max_fee_sat","coinjoin")) terms.put(key,body.get(key))
				lock?.let { terms.put("bond_locktime",it) }
				point?.let { terms.put("bond_outpoint",it).put("amount_sat",draft.amountSat) }
				fields.put("operation","prepare_payment").put("payment_id",draft.id).put("send",terms)
			}
			canSend && parts.size == 6 && parts.take(4) == listOf("wallet",wallet,"paperclip","payments") && JoinBlaketPayment.validId(parts[4]) -> {
				fields.put("payment_id",parts[4])
				when {
					parts[5] == "review" && body == null -> fields.put("operation","payment_review")
					parts[5] == "cancel" && body != null && body.length() == 0 -> fields.put("operation","cancel_payment")
					parts[5] == "commit" && body != null && body.length() == 1 && JoinBlaketPayment.validId(body.getString("approval")) && walletIdentity != null ->
						fields.put("operation","commit_payment").put("approval",body.getString("approval")).put("wallet_identity",walletIdentity)
					else -> error("This pairing does not permit that operation")
				}
			}
			parts.size == 3 && parts.take(2) == listOf("paperclip", "market") && body == null -> {
				val amount = parts[2].toLong(); require(amount in 27_300..2_100_000_000_000_000L)
				fields.put("operation", "market").put("comparison_sat", amount)
			}
			path == "session" && body == null -> fields.put("operation", "status")
			path == prefix + "paperclip/bonds" && body == null -> fields.put("operation","bonds")
			path == prefix + "utxos" && body == null -> fields.put("operation", "coins")
			parts.size == 5 && parts.take(4) == listOf("wallet", wallet, "address", "new") && body == null -> {
				val jar = parts[4].toIntOrNull(); require(jar != null && jar in 0..4)
				fields.put("operation", "address").put("jar", jar)
			}
			parts.size == 6 && parts.take(5) == listOf("wallet", wallet, "address", "timelock", "new") && body == null -> {
				JoinBlaketBond.validate(parts[5]); fields.put("operation", "bond_address").put("lock_month", parts[5])
			}
			path == prefix + "maker/start" && body != null -> {
				require(body.getString("txfee") == "0")
				fields.put("operation", "start_maker").put("minimum_sat", body.getString("minsize").toLong())
				if (body.getString("ordertype") == "sw0reloffer") {
					val rate = body.getString("cjfee_r")
					require(rate in JoinBlaketMakerFee.rates && body.getString("cjfee_a") == "0")
					fields.put("relative_fee", rate)
				} else {
					require(body.getString("ordertype") == "sw0absoffer" && body.getString("cjfee_r") == "0")
					fields.put("fee_sat", body.getString("cjfee_a").toLong())
				}
			}
			path == prefix + "maker/stop" && body == null -> fields.put("operation", "stop_maker")
			path == prefix + "paperclip/payments" && body == null -> fields.put("operation", "payments")
			parts.size == 5 && parts.take(4) == listOf("wallet", wallet, "paperclip", "payments") && body == null && JoinBlaketPayment.validId(parts[4]) ->
				fields.put("operation", "check_payment").put("payment_id", parts[4])
			else -> error("This pairing does not permit that operation")
		}
		return fields
	}
}

internal object JoinBlaketBond {
	fun locktime(month: String): Long {
		validate(month)
		return YearMonth.parse(month).atDay(1).atStartOfDay().toEpochSecond(ZoneOffset.UTC)
	}
	fun validate(month: String, now: Instant = Instant.now()) {
		require(month.matches(Regex("[0-9]{4}-[0-9]{2}"))) { "Choose an unlock month in YYYY-MM format" }
		val date = runCatching { YearMonth.parse(month) }.getOrNull()
		require(date != null && date.year in 2020..2099 && date.atDay(1).atStartOfDay().toInstant(ZoneOffset.UTC) > now) {
			"Choose a future month before 2100. Bonds unlock on its first day at 00:00 UTC."
		}
	}
}

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

/** Server recovery state. Never infer confirmation or retry a send from this record. */
internal data class JoinBlaketPayment(val id: String, val state: String, val quote: Quote?) {
	val canDiscard: Boolean get() = state in setOf("preparing", "prepared")
	data class Quote(val wallet: String, val jar: Int, val purpose: String, val destination: String,
		val txid: String, val amountSat: Long, val feeSat: Long, val totalSat: Long, val coinjoin: Boolean = false, val makerFeeSat: Long? = null,
		val miningFeeSat: Long? = null, val networkFeeSat: Long? = null, val makerCount: Int? = null, val broadcastPolicy: String? = null, val bondLocktime: Long? = null, val bondOutpoint: String? = null) {
		val bondUnlockDescription: String get() = bondLocktime?.let {
			java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm 'UTC'", java.util.Locale.ROOT)
				.withZone(java.time.ZoneOffset.UTC).format(Instant.ofEpochSecond(it))
		} ?: "Unavailable — check your Jam host"
	}
	val needsCheck: Boolean get() = state in setOf("submitting", "unknown")
	val label: String get() = when (state) {
		"preparing" -> "Review incomplete"
		"prepared" -> "Review saved"
		"submitting", "unknown" -> "Status unknown"
		"submitted" -> "Submitted"
		else -> "Cancelled"
	}
	companion object {
		fun validId(id: String) = id.matches(Regex("[0-9a-f]{64}"))
		fun parse(value: JSONObject, wallet: String): JoinBlaketPayment {
			val id = value.getString("id"); val state = value.getString("state")
			require(validId(id) && state in setOf("preparing", "prepared", "submitting", "unknown", "submitted", "cancelled")) { "Invalid Jam payment state" }
			if (value.isNull("quote")) {
				require(state in setOf("preparing", "cancelled")) { "Missing Jam payment details" }
				return JoinBlaketPayment(id, state, null)
			}
			val q = value.getJSONObject("quote")
			// JSONObject's getLong/getInt coerce fractional numbers and numeric strings.
			// Recovery amounts must instead be exact bounded JSON integers.
			fun integer(key: String): Long {
				val n = q.get(key)
				require(n is Int || n is Long) { "Invalid Jam payment amount" }
				return (n as Number).toLong().also { require(it in 0..2_100_000_000_000_000L) }
			}
			val jar = integer("jar"); val amount = integer("amount_sat"); val fee = integer("fee_sat"); val total = integer("total_sat")
			val purpose = q.getString("purpose"); val destination = q.getString("destination"); val txid = q.getString("txid")
			require(q.getString("wallet") == wallet) { "The saved payment belongs to a different Jam wallet" }
			require(jar in 0..4 && purpose in setOf("send", "fund_bond", "withdraw_bond") && validId(txid) &&
				destination.matches(Regex("[A-Za-z0-9]{14,90}")) && amount > 0 && amount + fee == total) { "Invalid Jam payment details" }
			val bondTime = if (q.isNull("bond_locktime")) null else integer("bond_locktime")
			require(bondTime == null || (purpose != "send" && bondTime in 1_577_836_800L..4_099_766_400L)) { "Invalid saved bond unlock date" }
			val point = if(q.isNull("bond_outpoint")) null else q.getString("bond_outpoint")
			require(point == null || (purpose == "withdraw_bond" && jar == 0L && JoinBlaketBondCoin.validOutpoint(point))) { "Invalid bond input" }
			val mode = if (q.has("coinjoin")) q.get("coinjoin") else false
			require(mode is Boolean) { "Invalid Jam payment mode" }
			if (mode) {
				val maker = integer("maker_fee_sat"); val mining = integer("mining_fee_sat"); val networkFee = integer("network_fee_sat"); val count = integer("maker_count")
				require(purpose == "send" && maker + mining == fee && mining <= networkFee && count in 2..20 && q.get("broadcast_policy") == "self") { "Invalid CoinJoin fee review" }
				return JoinBlaketPayment(id,state,Quote(wallet,jar.toInt(),purpose,destination,txid,amount,fee,total,true,maker,mining,networkFee,count.toInt(),"self"))
			}
			return JoinBlaketPayment(id, state, Quote(wallet, jar.toInt(), purpose, destination, txid, amount, fee, total, bondLocktime = bondTime, bondOutpoint = point))
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
	private val pairing: JoinBlaketPairing? = null,
) {
	companion object {
		suspend fun open(context: Context, connection: JoinBlaketConnection, pairing: JoinBlaketPairing? = null): JoinBlaketClient {
			connection.validate()
			require(pairing == null || pairing.connection == connection) { "Pairing connection changed" }
			val route = if (connection.proxy == "builtin") EmbeddedTor.proxy(context) else connection.proxy
			return JoinBlaketClient(connection, NodeHTTPTransport.create(connection.endpoint, connection.pin, route), pairing)
		}
	}

	internal suspend fun request(
		components: List<String>, authorization: JoinBlaketAuthorization? = null, body: JSONObject? = null, preparingCoinJoin: Boolean = false, walletIdentity: String? = null,
	): JSONObject {
		connection.validate()
		val url = connection.endpoint.toHttpUrl().newBuilder()
		for (part in if (pairing == null) listOf("api", "v1") + components else listOf("api", "v1", "paired-jars", "request")) {
			require(part.isNotEmpty() && '/' !in part && '\\' !in part && part !in setOf(".", "..")) { "Invalid Jam wallet path" }
			url.addPathSegment(part)
		}
		val request = Request.Builder().url(url.build()).header("Accept", "application/json")
		if (pairing != null) {
			require(authorization?.wallet == pairing.wallet && authorization.token == pairing.token && connection == pairing.connection) { "Pairing wallet or connection changed" }
			request.header("Authorization", "Bearer " + pairing.token)
			request.post(pairing.request(components, body, walletIdentity).toString().toRequestBody("application/json".toMediaType()))
		} else {
			authorization?.let { request.header("Authorization", "Bearer " + it.token) }
			body?.let { request.post(it.toString().toRequestBody("application/json".toMediaType())) }
		}
		val transport = if (preparingCoinJoin) client.newBuilder()
			.readTimeout(190, java.util.concurrent.TimeUnit.SECONDS).callTimeout(190, java.util.concurrent.TimeUnit.SECONDS)
			.retryOnConnectionFailure(false).build() else client
		val call = transport.newCall(request.build())
		return suspendCancellableCoroutine { continuation ->
			continuation.invokeOnCancellation { call.cancel() }
			call.enqueue(object : Callback {
				override fun onFailure(call: Call, e: IOException) { continuation.resumeWithException(e) }
				override fun onResponse(call: Call, response: Response) {
					try {
						val result = response.use {
							require(pairing == null || it.isSuccessful) { "Check Jars on your Paperclip host. If Jam locked or restarted, unlock it there and create a new pairing. Check status before retrying an action." }
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
	/** Registers an address only; never funds it or starts a maker. */
	suspend fun bondAddress(month: String, authorization: JoinBlaketAuthorization): String {
		JoinBlaketBond.validate(month)
		val current = status(authorization)
		require(!current.getBoolean("coinjoin_in_process") && !current.getBoolean("rescanning")) { "Wait for Jam to finish its current operation" }
		JoinBlaketBond.validate(month)
		val address = request(listOf("wallet", authorization.wallet, "address", "timelock", "new", month), authorization).getString("address")
		require(address.isNotEmpty() && address.length <= 128 && address.none(Char::isWhitespace)) { "Jam returned an invalid bond address" }
		return address
	}
	/** No fallback to legacy sends, no replay, and no missing-companion-as-empty-history. */
	suspend fun payments(authorization: JoinBlaketAuthorization): List<JoinBlaketPayment> {
		status(authorization)
		val rows = request(listOf("wallet", authorization.wallet, "paperclip", "payments"), authorization).getJSONArray("payments")
		require(rows.length() <= 100) { "Jam payment history too large" }
		val result = (0 until rows.length()).map { JoinBlaketPayment.parse(rows.getJSONObject(it), authorization.wallet) }
		require(result.map { it.id }.toSet().size == result.size) { "Duplicate Jam payment reference" }
		return result
	}
	suspend fun checkPayment(id: String, authorization: JoinBlaketAuthorization): JoinBlaketPayment {
		require(JoinBlaketPayment.validId(id)) { "Invalid Jam payment reference" }
		status(authorization)
		val result = JoinBlaketPayment.parse(request(listOf("wallet", authorization.wallet, "paperclip", "payments", id), authorization), authorization.wallet)
		require(result.id == id) { "Jam returned a different payment" }
		return result
	}

	suspend fun market(amount: Long, authorization: JoinBlaketAuthorization): JoinBlaketMarket {
		require(amount in 27_300..2_100_000_000_000_000L)
		status(authorization)
		return JoinBlaketMarket.parse(request(listOf("paperclip", "market", amount.toString()), authorization), amount)
	}
	val canDiscardReviews: Boolean get() = pairing == null || pairing.canSend
	val isPaired: Boolean get() = pairing != null
	/** Preserve management-only pairing scopes; uncertain submissions cannot be discarded. */
	suspend fun discardPayment(id: String, authorization: JoinBlaketAuthorization): JoinBlaketPayment {
		require(canDiscardReviews) { "Discard this review in Jars on your Paperclip host" }
		val saved = checkPayment(id, authorization)
		if (saved.state == "cancelled") return saved
		require(saved.canDiscard) { "Submission may have started; check status instead" }
		val result = JoinBlaketPayment.parse(request(listOf("wallet", authorization.wallet, "paperclip", "payments", id, "cancel"), authorization, JSONObject()), authorization.wallet)
		require(result.id == id && result.state == "cancelled") { "Could not confirm cancellation; refresh saved payments" }
		return result
	}

	suspend fun startMaker(minimumSat: Long, feeSat: Long, authorization: JoinBlaketAuthorization, relativeFee: String? = null) {
		require(if (relativeFee == null) feeSat in JoinBlaketMakerFee.fixed else relativeFee in JoinBlaketMakerFee.rates && feeSat == 0L) { "Choose a supported maker fee" }
		require(minimumSat in 27_300..2_100_000_000_000_000L && feeSat in 0 until minimumSat) { "Review the maker amount and fee" }
		val current = status(authorization)
		require(!current.getBoolean("maker_running") && !current.getBoolean("coinjoin_in_process") && !current.getBoolean("rescanning")) { "Wait for the current Jam operation to finish" }
		request(listOf("wallet", authorization.wallet, "maker", "start"), authorization,
			JSONObject().put("txfee", "0").put("cjfee_a", feeSat.toString()).put("cjfee_r", relativeFee ?: "0")
				.put("ordertype", if (relativeFee == null) "sw0absoffer" else "sw0reloffer").put("minsize", minimumSat.toString()))
	}
	suspend fun stopMaker(authorization: JoinBlaketAuthorization) {
		request(listOf("wallet", authorization.wallet, "maker", "stop"), authorization)
	}
}
