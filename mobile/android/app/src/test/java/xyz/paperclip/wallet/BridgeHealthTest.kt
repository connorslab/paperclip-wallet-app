package xyz.paperclip.wallet

import org.junit.Assert.*
import org.junit.Test

class BridgeHealthTest {
	@Test fun serviceObservationsExpireAndErrorsRemainUnknown() {
		val live = BridgeHealth(true, 1000)
		assertEquals(BridgeHealthState.LIVE, live.state(1000))
		assertFalse(live.shouldRefresh(30999))
		assertTrue(live.shouldRefresh(31000))
		assertEquals(BridgeHealthState.UNKNOWN, live.state(91000))
		assertEquals(BridgeHealthState.UNKNOWN, live.state(999))
		assertEquals(BridgeHealthState.PAUSED, BridgeHealth(false, 1000).state(1000))
		assertEquals(BridgeHealthState.UNKNOWN, BridgeHealth(null, 1000).state(1000))
		assertEquals(BridgeHealthState.CHECKING, BridgeHealth(checking = true).state(1000))
		assertFalse(BridgeHealth(checking = true).shouldRefresh(1000))
	}
	@Test fun directionsMustBothBeAvailableBeforeShowingLive() {
		assertEquals(BridgeHealthState.LIVE, BridgeHealthState.combined(BridgeHealthState.LIVE, BridgeHealthState.LIVE))
		assertEquals(BridgeHealthState.LIMITED, BridgeHealthState.combined(BridgeHealthState.LIVE, BridgeHealthState.PAUSED))
		assertEquals(BridgeHealthState.UNKNOWN, BridgeHealthState.combined(BridgeHealthState.LIVE, BridgeHealthState.UNKNOWN))
		assertEquals(BridgeHealthState.CHECKING, BridgeHealthState.combined(BridgeHealthState.PAUSED, BridgeHealthState.CHECKING))
	}
}
