package xyz.paperclip.wallet

import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class ReusableOfferTest {
	@Test fun canonicalOfferNetworkAndAmountBoundaries() {
		val cases = JSONArray(javaClass.classLoader!!.getResourceAsStream("bridge-reusable.json")!!.bufferedReader().readText())
		for (i in 0 until cases.length()) {
			val row = cases.getJSONObject(i)
			val accepted = runCatching { ReusableOffer.validate(row.getString("offer"), row.getBoolean("xbt")) }.isSuccess
			assertEquals(row.getString("name"), row.getBoolean("valid"), accepted)
		}
		assertFalse(runCatching { ReusableOffer.validate("lno1" + "q".repeat(16384), false) }.isSuccess)
	}
	@Test fun managementKeysCannotBeZeroOrUrlData() {
		assertTrue(ReusableOffer.validToken("ab".repeat(32)))
		for (value in listOf("", "0".repeat(64), "A".repeat(64), "https://example.com/?token=" + "a".repeat(64))) assertFalse(ReusableOffer.validToken(value))
	}
}
