package xyz.paperclip.wallet

import org.json.JSONObject

/** Bounded structural checks. Registration is not a payment or a receipt. */
internal object ReusableOffer {
	fun validToken(token: String) = token.matches(Regex("[0-9a-f]{64}")) && token.any { it != '0' }
	fun response(value: JSONObject) {
		require(value.opt("revoked") is Boolean && value.optString("direction") in listOf("toBLAKE2b", "toSHA256"))
		validate(value.getString("offer"), value.getString("direction") == "toSHA256", now = 0)
	}
	fun validate(text: String, xbt: Boolean, now: Long = System.currentTimeMillis() / 1000) {
		val message = "Use an unexpired, amountless mainnet BOLT12 offer for the selected receiving currency."
		require(text.length in 5..16384 && (text == text.lowercase() || text == text.uppercase()) && text.lowercase().startsWith("lno1")) { message }
		val alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
		var accumulator = 0; var bits = 0
		val bytes = mutableListOf<Int>()
		for (c in text.lowercase().drop(4)) {
			val n = alphabet.indexOf(c); require(n >= 0) { message }
			accumulator = ((accumulator shl 5) or n) and 65535; bits += 5
			if (bits >= 8) { bits -= 8; bytes.add((accumulator shr bits) and 255) }
		}
		require(bits < 5 && (accumulator and ((1 shl bits) - 1)) == 0) { message }
		var offset = 0
		fun bigSize(): Long {
			require(offset < bytes.size) { message }; val first = bytes[offset++]
			if (first < 253) return first.toLong()
			val count = if (first == 253) 2 else if (first == 254) 4 else 8
			require(offset + count <= bytes.size) { message }
			var value = 0L
			repeat(count) { require(value <= Long.MAX_VALUE / 256) { message }; value = value * 256 + bytes[offset++] }
			require(value >= if (count == 2) 253 else if (count == 4) 65536 else 4294967296L) { message }; return value
		}
		val fields = mutableMapOf<Long, List<Int>>(); var previous = -1L
		while (offset < bytes.size) {
			val type = bigSize(); val length = bigSize()
			require(type > previous && length <= bytes.size - offset && (type < 80 || type in 1000000000L..1999999999L)) { message }
			fields[type] = bytes.subList(offset, offset + length.toInt()).toList(); offset += length.toInt(); previous = type
		}
		require(6L !in fields && 8L !in fields && 20L !in fields && (22L in fields || 16L in fields)) { message }
		fields[2]?.let { require(it == "6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000".chunked(2).map { hex -> hex.toInt(16) }) { message } }
		val features = fields[12] ?: emptyList()
		val requiredXbt = features.size > 64 && features[features.size - 65] and 1 != 0
		val optionalXbt = features.size > 64 && features[features.size - 65] and 2 != 0
		require(requiredXbt == xbt && (!optionalXbt || requiredXbt)) { message }
		fields[14]?.let {
			require(it.size <= 8 && it.firstOrNull() != 0) { message }
			var value = 0L
			for (b in it) { require(value <= Long.MAX_VALUE / 256) { message }; value = value * 256 + b }
			require(value > now) { message }
		}
	}
}
