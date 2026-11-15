package xyz.paperclip.wallet

import org.junit.Assert.*
import org.junit.Test

class WalletNavigationTest {
    @Test fun nestedBackReturnsToParentAndKeepsSelectedTab() {
        val nested = WalletNavigation().selectTab("Settings").open("Coinjoin").open("Previous Coinjoin")
        assertEquals("Coinjoin", nested.back().route)
        assertEquals("Settings", nested.back().tab)
        assertEquals("Settings", nested.back().back().route)
        assertFalse(nested.back().back().canGoBack)
        assertEquals(nested, nested.open("Previous Coinjoin"))
    }
    @Test fun tabSwitchRestoresHistoryAndReselectionReturnsToOverview() {
        val settings = WalletNavigation().selectTab("Settings").open("Connections")
        val wallet = settings.selectTab("Wallet").open("Send")
        assertEquals("Connections", wallet.selectTab("Settings").route)
        assertEquals("Send", wallet.selectTab("Settings").selectTab("Wallet").route)
        assertEquals("Wallet", wallet.selectTab("Wallet").route)
    }
    @Test fun rotationAndAccountChangesKeepOnlyAppropriateNavigation() {
        val state = WalletNavigation().selectTab("Settings").open("Coinjoin").open("Previous Coinjoin")
        assertEquals(state, WalletNavigation.restore(state.saved()))
        assertEquals("Settings", state.resetPaths().route)
        assertEquals(WalletNavigation(), WalletNavigation.restore(listOf("unknown")))
    }
}
