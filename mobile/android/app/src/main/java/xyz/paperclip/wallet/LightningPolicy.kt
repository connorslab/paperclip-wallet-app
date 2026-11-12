package xyz.paperclip.wallet

import java.net.URI
import java.security.MessageDigest
import java.util.Base64
import org.json.JSONObject

internal fun nodeAmount(value: Any?): Long {
	val text =
		when (value) {
			is String -> value.removeSuffix("msat")
			is Number -> value.toString()
			else -> error("Invalid node amount")
		}
	require(text.matches(Regex("[0-9]+"))) { "Invalid node amount" }
	return text.toLong().also { require(it >= 0) }
}

internal fun hashHex(value: String): String {
	val bytes = Base64.getDecoder().decode(value)
	require(bytes.size == 32) { "Invalid payment hash" }
	return bytes.joinToString("") { "%02x".format(it) }
}

data class NodeConnection(
	val implementation: String = "lnd",
	val endpoint: String = "",
	val credential: String = "",
	val pin: String = "",
	val proxy: String = "builtin",
) {
	fun validate() {
		require(implementation in setOf("lnd", "cln"))
		val uri = URI(endpoint)
		require(
			uri.scheme in setOf("https", "http") &&
				!uri.host.isNullOrBlank() &&
				uri.port in -1..65535 &&
				uri.port != 0 &&
				uri.rawUserInfo == null &&
				uri.rawQuery == null &&
				uri.rawFragment == null,
		) {
			"Enter a REST endpoint without credentials"
		}
		require(
			uri.scheme == "https" ||
				(uri.host.lowercase().endsWith(".onion") && proxy.isNotBlank() && pin.isEmpty()),
		) {
			"Use HTTPS with certificate validation, or an explicitly configured HTTP onion service through Tor without a TLS pin"
		}
		require(!uri.host.lowercase().endsWith(".onion") || proxy.isNotBlank()) {
			"Onion nodes require Tor"
		}
		require(
			credential.isNotEmpty() &&
				credential.length < 16384 &&
				credential.none { it.code < 32 || it.code > 126 },
		) {
			"Enter a valid node credential"
		}
		require(
			implementation != "lnd" ||
				(credential.length % 2 == 0 && credential.matches(Regex("[0-9a-fA-F]+"))),
		) {
			"LND requires a hexadecimal macaroon"
		}
		require(pin.isEmpty() || pin.matches(Regex("[0-9a-fA-F]{64}"))) {
			"Certificate SHA256 must contain 64 hexadecimal characters"
		}
		if (proxy.isNotBlank() && proxy != "builtin") {
			val p = URI(proxy)
			require(
				p.scheme == "socks5h" &&
					p.host != null &&
					p.port in 1..65535 &&
					p.rawUserInfo == null &&
					p.rawQuery == null &&
					p.rawFragment == null &&
					p.rawPath.isNullOrEmpty() &&
					!p.host.lowercase().endsWith(".onion"),
			) {
				"Use socks5h://host:port"
			}
		}
	}

	fun json() =
		JSONObject()
			.put("implementation", implementation)
			.put("endpoint", endpoint)
			.put("credential", credential)
			.put("pin", pin)
			.put("proxy", proxy)

	companion object {
		fun from(j: JSONObject) =
			NodeConnection(
				j.getString("implementation"),
				j.getString("endpoint"),
				j.getString("credential"),
				j.optString("pin"),
				j.optString("proxy"),
			)
	}
}

data class NodeBalance(
	val sendable: Long,
	val receivable: Long,
	val channels: Int,
	val local: Long?,
	val reserve: Long?,
) {
	companion object {
		fun decode(j: JSONObject, lnd: Boolean): NodeBalance {
			var send = 0L
			var receive = 0L
			var local = 0L
			var reserve = 0L
			var count = 0
			val channels = j.getJSONArray("channels")
			for (i in 0 until channels.length()) {
				val c = channels.getJSONObject(i)
				if (lnd) {
					if (c.opt("active") != true) continue
					val l = nodeAmount(c.get("local_balance"))
					val r = nodeAmount(c.get("remote_balance"))
					val lr =
						nodeAmount(
							c.optJSONObject("local_constraints")?.opt("chan_reserve_sat")
								?: c.opt("local_chan_reserve_sat"),
						)
					val rr =
						nodeAmount(
							c.optJSONObject("remote_constraints")?.opt("chan_reserve_sat")
								?: c.opt("remote_chan_reserve_sat"),
						)
					local = Math.addExact(local, Math.multiplyExact(l, 1000))
					reserve = Math.addExact(reserve, Math.multiplyExact(lr, 1000))
					send = Math.addExact(send, Math.multiplyExact((l - lr).coerceAtLeast(0), 1000))
					receive =
						Math.addExact(receive, Math.multiplyExact((r - rr).coerceAtLeast(0), 1000))
				} else {
					if (
						c.optString("state") != "CHANNELD_NORMAL" || c.opt("peer_connected") != true
					)
						continue
					send = Math.addExact(send, nodeAmount(c.get("spendable_msat")))
					receive = Math.addExact(receive, nodeAmount(c.get("receivable_msat")))
				}
				count++
			}
			return NodeBalance(
				send,
				receive,
				count,
				if (lnd) local else null,
				if (lnd) reserve else null,
			)
		}
	}
}

data class NodeInvoiceReview(
	val invoice: String,
	val hash: String,
	val msat: Long,
	val expires: Long,
	val feeSat: Long,
) {
	fun valid(now: Long = System.currentTimeMillis() / 1000) = expires > now
}

internal object LndBolt12 {
	fun offer(j: JSONObject, now: Long): Long? {
		require(
			j.getString("type") == "offer" &&
				j.opt("valid") == true &&
				j.opt("for_this_chain") == true,
		) {
			"Invalid offer or wrong chain"
		}
		val o = j.getJSONObject("offer")
		require(nodeAmount(o.opt("quantity_max") ?: "0") == 0L && o.opt("quantity_any") != true) {
			"Quantity offers are unsupported"
		}
		val expiry = nodeAmount(o.opt("absolute_expiry") ?: "0")
		require(expiry == 0L || expiry > now) { "Offer expired" }
		return nodeAmount(o.opt("amount_msat") ?: "0").takeIf { it > 0 }
	}

	fun invoice(j: JSONObject, encoded: String, fee: Long, now: Long): NodeInvoiceReview {
		require(j.getString("type") == "invoice" && j.opt("for_this_chain") == true) {
			"Invalid invoice or wrong chain"
		}
		val i = j.getJSONObject("invoice")
		require(i.opt("signature_valid") == true) { "Invalid invoice signature" }
		val expiry = relativeExpiry(encoded)
		val reported = nodeAmount(i.opt("relative_expiry") ?: "0")
		require(reported == expiry || (reported == 0L && expiry == 7200L)) {
			"Inconsistent invoice expiry"
		}
		val expires = Math.addExact(nodeAmount(i.get("created_at")), expiry)
		val amount = nodeAmount(i.get("amount_msat"))
		require(amount > 0 && expires > now) { "Invoice expired or has no amount" }
		require(fee > 0 && fee <= Long.MAX_VALUE / 1000) {
			"XBT LND BOLT12 requires a positive maximum fee; zero uses the node default"
		}
		return NodeInvoiceReview(
			encoded,
			hashHex(i.getString("payment_hash")),
			amount,
			expires,
			fee,
		)
	}

	fun relativeExpiry(invoice: String): Long {
		require(
			invoice.length <= 256 * 1024 &&
				(invoice == invoice.lowercase() || invoice == invoice.uppercase()) &&
				invoice.lowercase().startsWith("lni1"),
		)
		val alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
		val bytes = ArrayList<Int>()
		var accumulator = 0
		var bits = 0
		for (c in invoice.lowercase().drop(4)) {
			val word = alphabet.indexOf(c)
			require(word >= 0)
			accumulator = ((accumulator shl 5) or word) and 65535
			bits += 5
			if (bits >= 8) {
				bits -= 8
				bytes += (accumulator shr bits) and 255
			}
		}
		require(bytes.isNotEmpty() && bits < 5 && accumulator and ((1 shl bits) - 1) == 0)
		var offset = 0
		fun bigSize(): ULong {
			require(offset < bytes.size)
			val prefix = bytes[offset++]
			if (prefix < 253) return prefix.toULong()
			val length = if (prefix == 253) 2 else if (prefix == 254) 4 else 8
			require(length <= bytes.size - offset)
			var result = 0uL
			repeat(length) { result = (result shl 8) or bytes[offset++].toULong() }
			require(
				result >=
					if (prefix == 253) 253uL else if (prefix == 254) 65536uL else 4294967296uL,
			)
			return result
		}
		var previous: ULong? = null
		var expiry = 7200L
		while (offset < bytes.size) {
			val type = bigSize()
			val length = bigSize()
			require(
				(previous == null || type > previous!!) &&
					length <= (bytes.size - offset).toULong(),
			)
			previous = type
			if (type == 166uL) {
				require(length <= 4uL && (length == 0uL || bytes[offset] != 0))
				expiry = 0
				repeat(length.toInt()) { expiry = (expiry shl 8) or bytes[offset + it].toLong() }
			}
			offset += length.toInt()
		}
		return expiry
	}

	fun result(j: JSONObject, review: NodeInvoiceReview): JSONObject {
		val hash = hashHex(j.getString("payment_hash"))
		val preimage = Base64.getDecoder().decode(j.getString("payment_preimage"))
		try {
			require(
				preimage.size == 32 &&
					j.getString("bolt12") == review.invoice &&
					hash == review.hash,
			)
			val actual =
				MessageDigest.getInstance("SHA-256").digest(preimage).joinToString("") {
					"%02x".format(it)
				}
			require(actual == hash) { "Payment proof did not match the reviewed invoice" }
			return JSONObject().put("payment_hash", hash).put("status", "SUCCEEDED")
		} finally {
			preimage.fill(0)
		}
	}
}

internal enum class NodeNetwork {
	MAINNET,
	REGTEST;

	fun accepts(invoice: String) =
		invoice.lowercase().let {
			it.startsWith("lni1") ||
				it.startsWith("lno1") ||
				if (this == MAINNET) it.startsWith("lnbc") && !it.startsWith("lnbcrt")
				else it.startsWith("lnbcrt")
		}

	companion object {
		fun decode(info: JSONObject, lnd: Boolean): NodeNetwork {
			val network =
				if (lnd) {
					val chains = info.getJSONArray("chains")
					require(
						chains.length() == 1 &&
							chains.getJSONObject(0).getString("chain") == "bitcoin",
					) {
						"Connect an XBT mainnet or regtest node"
					}
					chains.getJSONObject(0).getString("network")
				} else info.getString("network")
			return when (network) {
				if (lnd) "mainnet" else "bitcoin" -> MAINNET
				"regtest" -> REGTEST
				else -> error("Connect an XBT mainnet or regtest node")
			}
		}
	}
}
