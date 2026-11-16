package xyz.paperclip.wallet

/** Availability never establishes settlement of an existing payment. */
internal enum class BridgeHealthState(val title: String) {
	CHECKING("Checking"), LIVE("Live"), PAUSED("Paused"), UNKNOWN("Status unknown"), LIMITED("Limited");
	companion object {
		fun combined(pay: BridgeHealthState, receive: BridgeHealthState): BridgeHealthState = when {
			pay == receive -> pay
			pay == CHECKING || receive == CHECKING -> CHECKING
			pay == UNKNOWN || receive == UNKNOWN -> UNKNOWN
			else -> LIMITED
		}
	}
}

internal data class BridgeHealth(val open: Boolean? = null, val checkedAt: Long? = null, val checking: Boolean = false) {
	fun state(now: Long): BridgeHealthState = when {
		checking -> BridgeHealthState.CHECKING
		checkedAt == null || open == null || now - checkedAt !in 0 until 90000 -> BridgeHealthState.UNKNOWN
		open -> BridgeHealthState.LIVE
		else -> BridgeHealthState.PAUSED
	}
	fun shouldRefresh(now: Long) = !checking && (checkedAt == null || now - checkedAt !in 0 until 30000)
}
