package xyz.paperclip.wallet

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class BridgeInvoiceTest {
	private val now = 1_800_000_000L

	// Dummy signatures are intentional: funding uses the node/native verifier.
	private fun invoice(
		xbt: Boolean = false,
		amount: String = "10000n",
		hashByte: Int = 1,
	): String {
		val alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
		val hrp = "lnbc$amount"
		fun words(n: Long, count: Int) =
			(count - 1 downTo 0).map { ((n ushr (it * 5)) and 31).toInt() }
		val data = words(now, 7).toMutableList()
		val hash = mutableListOf<Int>()
		var acc = 0
		var bits = 0
		repeat(32) {
			acc = ((acc shl 8) or hashByte) and 65535
			bits += 8
			while (bits >= 5) {
				bits -= 5
				hash += (acc shr bits) and 31
			}
		}
		if (bits > 0) hash += (acc shl (5 - bits)) and 31
		data += listOf(1, 1, 20) + hash
		data += listOf(6, 0, 7) + words(3600, 7)
		if (xbt) data += listOf(5, 3, 7) + listOf(8) + List(102) { 0 }
		data += List(104) { 0 }
		val generators = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
		var checksum = 1
		val expanded = hrp.map { it.code shr 5 } + listOf(0) + hrp.map { it.code and 31 }
		for (word in expanded + data + List(6) { 0 }) {
			val top = checksum ushr 25
			checksum = ((checksum and 0x1ffffff) shl 5) xor word
			for (i in 0..4) if ((top shr i) and 1 != 0) checksum = checksum xor generators[i]
		}
		data += words((checksum xor 1).toLong(), 6)
		return hrp + "1" + data.map { alphabet[it] }.joinToString("")
	}

	private fun quote(hold: String, hash: String) =
		JSONObject()
			.put("hold_invoice", hold)
			.put("hash", hash)
			.put("sat", 1000)
			.put("pay_sat", 1000)
			.put("rate", 0.5)
			.put("spread", 0.02)
			.put("expires_at", now + 60)
			.put("token", "a".repeat(32))

	@Test
	fun commitmentParserChecksNetworkAmountAndEncoding() {
		val target = BridgeInvoice(invoice())
		assertEquals(1_000_000L, target.msat)
		assertFalse(target.xbt)
		target.validateTarget(false, now)
		assertTrue(BridgeInvoice(invoice(true)).xbt)
		assertThrows(IllegalArgumentException::class.java) {
			BridgeInvoice(invoice(true)).validateTarget(false, now)
		}
		assertThrows(IllegalArgumentException::class.java) { BridgeInvoice(invoice(amount = "1p")) }
		assertThrows(IllegalArgumentException::class.java) {
			BridgeInvoice(invoice().dropLast(1) + "q")
		}
		assertThrows(IllegalArgumentException::class.java) {
			BridgeInvoice("L" + invoice().drop(1))
		}
		assertEquals(target.hash, BridgeInvoice(invoice().uppercase()).hash)
	}

	@Test
	fun quoteMustBindBothInvoicesAmountNetworkAndExpiry() {
		val target = BridgeInvoice(invoice())
		val valid = quote(invoice(true), target.hash)
		assertEquals(target.hash, BridgeQuote(valid).validate(target, false, now).hash)
		val invalid =
			listOf(
				quote(invoice(true, hashByte = 2), target.hash),
				quote(invoice(false), target.hash),
				JSONObject(valid.toString()).put("pay_sat", 999),
				JSONObject(valid.toString()).put("sat", 999),
				JSONObject(valid.toString()).put("expires_at", now + 4),
				JSONObject(valid.toString()).put("expires_at", now + 4000),
			)
		for (value in invalid) assertThrows(IllegalArgumentException::class.java) {
			BridgeQuote(value).validate(target, false, now)
		}
		val reverseTarget = BridgeInvoice(invoice(true))
		assertFalse(
			BridgeQuote(quote(invoice(false), reverseTarget.hash))
				.validate(reverseTarget, true, now)
				.xbt,
		)
	}
}
