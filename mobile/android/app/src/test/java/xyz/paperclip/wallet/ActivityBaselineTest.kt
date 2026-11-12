package xyz.paperclip.wallet

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ActivityBaselineTest {
	@Test
	fun existingHistoryIsQuietAndSettlementNotifiesOnlyOnce() {
		val initial = WalletActivity("one", "On-chain", "pending", 1000, 100, false)
		val baseline = ActivityBaseline()
		assertTrue(baseline.changes(listOf(initial), 200).isEmpty())
		val reopened = ActivityBaseline(JSONObject(baseline.json().toString()))
		val completed = initial.copy(status = "confirmed")
		assertEquals(listOf(completed), reopened.changes(listOf(completed), 300))
		assertTrue(reopened.changes(listOf(completed), 400).isEmpty())
		assertTrue(reopened.changes(listOf(initial.copy(id = "old", time = 50)), 500).isEmpty())
		assertTrue(
			reopened
				.changes(listOf(initial.copy(id = "zero", amount = 0, time = 600)), 600)
				.isEmpty(),
		)
	}
}
