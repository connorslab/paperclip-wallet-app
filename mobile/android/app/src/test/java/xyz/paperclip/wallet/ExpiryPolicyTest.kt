package xyz.paperclip.wallet

import org.junit.Assert.*
import org.junit.Test

class ExpiryPolicyTest {
	@Test
	fun expiredFundsRequireRecoveryRatherThanAnEstimatedRenewal() {
		assertEquals(listOf(ExpiryNotice("recovery", 5)), ExpiryPolicy.plan(100, 100))
		assertTrue(ExpiryPolicy.plan(100, null).isEmpty())
		assertTrue(ExpiryPolicy.plan(-1, 100).isEmpty())
	}

	@Test
	fun urgentWindowsCoalesceAndRetainOfflineCheck() {
		assertEquals(
			listOf(ExpiryNotice("now", 5), ExpiryNotice("check", 21600)),
			ExpiryPolicy.plan(100, 150),
		)
		val planned = ExpiryPolicy.plan(100, 300)
		assertEquals(listOf("now", "144", "72", "check"), planned.map { it.id })
		assertEquals(33600L, planned.first { it.id == "144" }.delaySeconds)
	}

	@Test
	fun futureWindowsUseSameBlockEstimateAsIos() {
		assertEquals(
			listOf(
				ExpiryNotice("432", 40800),
				ExpiryNotice("144", 213600),
				ExpiryNotice("72", 256800),
				ExpiryNotice("check", 21600),
			),
			ExpiryPolicy.plan(100, 600),
		)
	}
}
