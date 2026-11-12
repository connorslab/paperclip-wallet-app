package xyz.paperclip.wallet

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class LightningPolicyTest {
	@Test
	fun httpOnionRequiresTorAndCannotSilentlyIgnoreATlsPin() {
		val onion =
			NodeConnection(
				endpoint = "http://example.onion:8180",
				credential = "00",
				proxy = "builtin",
			)
		onion.validate()
		for (connection in
			listOf(
				onion.copy(proxy = ""),
				onion.copy(pin = "11".repeat(32)),
				onion.copy(endpoint = "http://example.com:8180"),
			)) {
			assertThrows(IllegalArgumentException::class.java) { connection.validate() }
		}
	}

	@Test
	fun receivedFundsBelowReserveRemainVisible() {
		val j =
			JSONObject(
				"""{"channels":[{"active":true,"local_balance":"230000","remote_balance":"49770000","local_constraints":{"chan_reserve_sat":"500000"},"remote_constraints":{"chan_reserve_sat":"500000"}}]}""",
			)
		val b = NodeBalance.decode(j, true)
		assertEquals(230000000L, b.local)
		assertEquals(500000000L, b.reserve)
		assertEquals(0L, b.sendable)
		assertEquals(49270000000L, b.receivable)
	}

	@Test
	fun reservesApplyPerChannel() {
		val j =
			JSONObject(
				"""{"channels":[{"active":true,"local_balance":"700000","remote_balance":"1","local_chan_reserve_sat":"500000","remote_chan_reserve_sat":"0"},{"active":true,"local_balance":"0","remote_balance":"1","local_chan_reserve_sat":"500000","remote_chan_reserve_sat":"0"}]}""",
			)
		assertEquals(200000000L, NodeBalance.decode(j, true).sendable)
	}

	@Test
	fun malformedAmountsCannotBecomeBalances() {
		for (bad in listOf<Any>(true, -1, "-1", "1.5", "9223372036854775808")) {
			assertThrows(Exception::class.java) { nodeAmount(bad) }
		}
	}

	@Test
	fun onionCannotSilentlyUseDirectConnection() {
		assertThrows(IllegalArgumentException::class.java) {
			NodeConnection(endpoint = "https://example.onion:8180", credential = "00", proxy = "")
				.validate()
		}
	}

	@Test
	fun offerReviewChecksChainExpiryAndQuantity() {
		val o =
			JSONObject(
				"""{"type":"offer","valid":true,"for_this_chain":true,"offer":{"amount_msat":"230000000"}}""",
			)
		assertEquals(230000000L, LndBolt12.offer(o, 100))
		o.put("for_this_chain", false)
		assertThrows(IllegalArgumentException::class.java) { LndBolt12.offer(o, 100) }
		o.put("for_this_chain", true).getJSONObject("offer").put("absolute_expiry", "99")
		assertThrows(IllegalArgumentException::class.java) { LndBolt12.offer(o, 100) }
	}

	private fun encoded(vararg bytes: Int): String {
		val alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
		var accumulator = 0
		var bits = 0
		val out = StringBuilder("lni1")
		for (b in bytes) {
			accumulator = (accumulator shl 8) or b
			bits += 8
			while (bits >= 5) {
				bits -= 5
				out.append(alphabet[(accumulator shr bits) and 31])
			}
		}
		if (bits > 0) out.append(alphabet[(accumulator shl (5 - bits)) and 31])
		return out.toString()
	}

	@Test
	fun bolt12ExpiryPreservesZeroAndRejectsNoncanonicalTlv() {
		assertEquals(7200L, LndBolt12.relativeExpiry(encoded(2, 0)))
		assertEquals(0L, LndBolt12.relativeExpiry(encoded(166, 0)))
		assertEquals(60L, LndBolt12.relativeExpiry(encoded(166, 1, 60)))
		for (bad in
			listOf(
				encoded(166, 1, 0),
				encoded(166, 0, 166, 0),
				encoded(253, 0, 166, 0),
				encoded(166, 4, 1),
			)) {
			assertThrows(IllegalArgumentException::class.java) { LndBolt12.relativeExpiry(bad) }
		}
	}
}
