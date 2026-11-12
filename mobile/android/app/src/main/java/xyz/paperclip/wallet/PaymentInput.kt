package xyz.paperclip.wallet

import java.net.URLDecoder

internal data class ScannedPayment(val destination: String, val amount: Long?)

internal object PaymentInput {
	fun normalize(text: String): String {
		val value = text.trim()
		return if (value.startsWith("lightning:", true)) value.drop(10) else value
	}

	fun scan(text: String): ScannedPayment {
		val value = normalize(text)
		require(
			value.isNotEmpty() &&
				value.toByteArray().size <= 16384 &&
				value.none { it.isWhitespace() },
		)
		if (value.startsWith("bitcoin:", true)) {
			val parts = value.drop(8).split('?', limit = 2)
			val address = parts[0]
			require(address.isNotEmpty() && address.none { it in "/%#:@" } && !value.contains('#'))
			val query =
				if (parts.size == 1) emptyList()
				else
					parts[1].split('&').map { entry ->
						val pair = entry.split('=', limit = 2)
						URLDecoder.decode(pair[0], "UTF-8") to
							pair.getOrNull(1)?.let { URLDecoder.decode(it, "UTF-8") }
					}
			require(
				query.none { it.first.startsWith("req-", true) } &&
					query.count { it.first == "amount" } <= 1,
			)
			val amount =
				query
					.firstOrNull { it.first == "amount" }
					?.let { (_, raw) ->
						require(raw != null && raw.matches(Regex("[0-9]+(?:\\.[0-9]{1,8})?")))
						checkNotNull(BitcoinUnit.XBT.parse(raw)).also { require(it > 0) }
					}
			return ScannedPayment(address, amount)
		}
		require(value.none { it in ":?#" })
		return ScannedPayment(value, null)
	}
}
