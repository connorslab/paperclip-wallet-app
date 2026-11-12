package xyz.paperclip.wallet

import android.content.Intent
import android.view.WindowManager
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

class MainnetSafetyTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun screenshotModeCannotReadOrRestoreMainnetWallet(): Unit = runBlocking {
        org.junit.Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("mainnetSafety") == "true")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val engine = WalletEngine.shared(context)
        check(!engine.hasWallet()) { "Run this test only in a fresh test installation" }
        val key = BackupCodec.newKey()
        val archive = BackupCodec.seal(JSONObject().put("version", 1)
            .put("network", "xbt-mainnet").toString().toByteArray(), key)
        var rejected = false
        try { engine.restore(archive, key, testOnly = true) }
        catch (e: IllegalArgumentException) { rejected = e.message?.contains("Screenshot mode") == true }
        assertTrue("Mainnet restore must be rejected before writing a wallet", rejected)
        assertFalse(engine.hasWallet())

        val root = File(context.noBackupFilesDir, "wallets")
        val existing = root.listFiles().orEmpty().toSet()
        try {
            engine.create(engine.phrase(), "xbt-mainnet")
            assertEquals("xbt-mainnet", engine.network())
            assertTrue(engine.call("address_onchain").getString("address").startsWith("bc1"))
            engine.close()
            ActivityScenario.launch<MainActivity>(Intent(context, MainActivity::class.java)
                .putExtra("regtestScreenshots", true)).use { scenario ->
                compose.waitUntil(15_000) {
                    compose.onAllNodesWithText("Screenshot mode cannot open a mainnet wallet. Restart normally to unlock.")
                        .fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNodeWithText("Unlock Paperclip").assertIsDisplayed()
                scenario.onActivity { activity ->
                    assertTrue(activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
                }
            }
        } finally {
            engine.close()
            // Only the fresh, unfunded test wallet above is removed.
            File(context.noBackupFilesDir, "vault/wallet").delete()
            root.listFiles().orEmpty().filter { it !in existing }.forEach { it.deleteRecursively() }
        }
    }
}
