package xyz.paperclip.wallet

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Exercises a real reset failure and restores the previous alert state/preferences. */
class PaymentSettingsStorageTest {
    @get:Rule val compose = createComposeRule()

    @Test fun failedAlertResetKeepsTheToggleAndAllowsRetry() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val vault = SecureStore(context)
        val original = vault.read("payment-alert-state")
        val prefs = context.getSharedPreferences("payment-options", 0)
        val hadPreference = prefs.contains("alerts")
        val previous = prefs.getBoolean("alerts", false)
        val blocked = File(context.noBackupFilesDir, "vault/payment-alert-state.new")
        check(!blocked.exists()) { "Preserve existing staged alert state" }
        val marker = File(blocked, "keep")
        try {
            check(blocked.mkdir())
            marker.writeText("Preserve unrelated fixture contents")
            check(prefs.edit().putBoolean("alerts", true).commit())
            compose.setContent {
                MaterialTheme { Column(Modifier.verticalScroll(rememberScrollState())) { PaymentSettings() } }
            }
            val toggle = compose.onAllNodes(isToggleable()).onFirst()
            toggle.assertIsOn().performClick()
            compose.onNodeWithText("Could not update payment alerts. Check device storage and try again.").assertExists()
            toggle.assertIsOn()
            assertTrue(prefs.getBoolean("alerts", false))
            assertEquals("Preserve unrelated fixture contents", marker.readText())
            check(marker.delete()); check(blocked.delete())
            toggle.performClick().assertIsOff()
            compose.onNodeWithText("Could not update payment alerts. Check device storage and try again.").assertDoesNotExist()
            assertFalse(prefs.getBoolean("alerts", true))
            assertNull(vault.read("payment-alert-state"))
        } finally {
            marker.delete(); blocked.delete()
            if (original != null) { vault.write("payment-alert-state", original); original.fill(0) }
            else vault.delete("payment-alert-state")
            val edit = prefs.edit()
            if (hadPreference) edit.putBoolean("alerts", previous) else edit.remove("alerts")
            check(edit.commit())
        }
    }
}
