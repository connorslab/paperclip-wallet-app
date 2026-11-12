package xyz.paperclip.wallet

import org.junit.Assert.*
import org.junit.Test

class DisplayValuesTest {
	@Test
	fun paymentAmountsUseExactIntegerConversion() {
		assertEquals(1L, BitcoinUnit.XBT.parse("0.00000001"))
		assertEquals(123456789L, BitcoinUnit.XBT.parse("1,23456789"))
		assertNull(BitcoinUnit.XBT.parse("1.000000001"))
		assertNull(BitcoinUnit.XBT.parse("21000000.00000001"))
		assertNull(BitcoinUnit.SATS.parse("1.1"))
		assertNull(BitcoinUnit.XBT.parse("1e3"))
		assertEquals("1.00000001 XBT", BitcoinUnit.XBT.display(100000001))
	}

	@Test
	fun draftsAndMillisatoshiDisplaysNeverRoundMoney() {
		assertEquals("0.00000001", BitcoinUnit.XBT.input(1))
		assertEquals("1", BitcoinUnit.XBT.backendAmount("0.00000001"))
		assertEquals("invalid", BitcoinUnit.XBT.backendAmount("0.000000001"))
		assertEquals("", BitcoinUnit.XBT.backendAmount(""))
		assertEquals("0.001 sats", BitcoinUnit.SATS.displayMsat(1))
		assertEquals("0.00000000001 XBT", BitcoinUnit.XBT.displayMsat(1))
	}

	@Test
	fun staleFutureOrInvalidPublicPricesAreRejected() {
		val now = 1800000000000L
		assertTrue(PublicQuote(1.0, now).valid(now))
		assertFalse(PublicQuote(1.0, now - 86400000).valid(now))
		assertFalse(PublicQuote(1.0, now + 300001).valid(now))
		assertFalse(PublicQuote(Double.NaN, now).valid(now))
		assertFalse(PublicQuote(-1.0, now).valid(now))
	}
}
