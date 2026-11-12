package xyz.paperclip.wallet

/**
 * Checks the payment commitment; the node/native decoder still verifies signatures before funding.
 */
internal class BridgeInvoice(input: String) {
	val text: String
	val hash: String
	val msat: Long
	val expires: Long
	val xbt: Boolean

	init {
		val raw = input.trim().replace(Regex("(?i)^lightning:"), "")
		require(raw.length in 100..2000 && (raw == raw.lowercase() || raw == raw.uppercase())) {
			"Use a valid fixed-amount invoice"
		}
		text = raw.lowercase()
		val separator = text.lastIndexOf('1')
		require(separator > 0)
		val hrp = text.take(separator)
		require(hrp.startsWith("lnbc") && !hrp.startsWith("lnbcrt")) { "Use a mainnet invoice" }
		val alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
		val words =
			text.drop(separator + 1).map { alphabet.indexOf(it).also { n -> require(n >= 0) } }
		val expanded = hrp.map { it.code shr 5 } + listOf(0) + hrp.map { it.code and 31 }
		val generators = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
		var checksum = 1
		for (w in expanded + words) {
			val top = checksum ushr 25
			checksum = ((checksum and 0x1ffffff) shl 5) xor w
			for (i in 0..4) if ((top shr i) and 1 != 0) checksum = checksum xor generators[i]
		}
		require(checksum == 1 && words.size >= 117) { "Invalid invoice checksum" }
		var amount = hrp.drop(4)
		var multiplier = 100000000000L
		if (amount.lastOrNull()?.isDigit() == false) {
			val suffix = amount.last()
			amount = amount.dropLast(1)
			multiplier =
				when (suffix) {
					'm' -> 100000000
					'u' -> 100000
					'n' -> 100
					'p' -> 0
					else -> error("Invalid invoice amount")
				}
		}
		require(amount.matches(Regex("[0-9]+")))
		val n = amount.toLong()
		require(n > 0)
		msat =
			if (multiplier == 0L) {
				require(n % 10 == 0L)
				n / 10
			} else Math.multiplyExact(n, multiplier)
		require(msat in 1..2100000000000000000L)
		val fields = words.dropLast(110)
		fun integer(values: List<Int>): Long {
			var v = 0L
			for (w in values) v = Math.addExact(Math.multiplyExact(v, 32), w.toLong())
			return v
		}
		val timestamp = integer(fields.take(7))
		var expiry = 3600L
		var paymentHash: String? = null
		var isXbt = false
		var offset = 7
		val seen = mutableSetOf<Int>()
		while (offset < fields.size) {
			require(offset + 3 <= fields.size)
			val tag = fields[offset]
			val length = fields[offset + 1] * 32 + fields[offset + 2]
			offset += 3
			require(length <= fields.size - offset)
			val field = fields.subList(offset, offset + length)
			offset += length
			if (tag in listOf(1, 6, 5)) require(seen.add(tag))
			when (tag) {
				1 -> {
					require(length == 52 && field.last() and 15 == 0)
					var acc = 0
					var bits = 0
					val bytes = mutableListOf<Int>()
					for (w in field) {
						acc = ((acc shl 5) or w) and 65535
						bits += 5
						if (bits >= 8) {
							bits -= 8
							bytes += (acc shr bits) and 255
						}
					}
					paymentHash = bytes.joinToString("") { "%02x".format(it) }
				}
				6 -> expiry = integer(field)
				5 ->
					for (bit in listOf(512, 513)) if (
						length > bit / 5 && field[length - 1 - bit / 5] and (1 shl (bit % 5)) != 0
					)
						isXbt = true
			}
		}
		hash = checkNotNull(paymentHash)
		expires = Math.addExact(timestamp, expiry)
		xbt = isXbt
	}

	fun validateTarget(receiveXbt: Boolean, now: Long = System.currentTimeMillis() / 1000) {
		require(xbt == receiveXbt) { "Invoice belongs to the wrong receiving network" }
		require(expires > now + 300) { "Use an invoice with at least five minutes remaining" }
	}
}
