package xyz.paperclip.wallet

import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Runs against the actual JNI engine, without any mock wallet balances. */
class WalletScreensTest {
    @get:Rule val compose = createEmptyComposeRule()
    private fun capture(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val folder = File(instrumentation.targetContext.getExternalFilesDir(null), "screenshots").apply { mkdirs() }
        File(folder, "$name.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }
    private fun waitFor(text: String) {
        compose.waitUntil(30_000) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }
    }
    private fun click(text: String) { compose.onNodeWithText(text).performScrollTo().performClick() }
    @Test fun nativeWalletAndNavigation() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val intent = Intent(context, MainActivity::class.java).putExtra("regtestScreenshots", true)
        ActivityScenario.launch<MainActivity>(intent).use {
            waitFor("Create a test wallet"); capture("01-onboarding")
            click("Create a test wallet")
            waitFor("I saved these test recovery words")
            compose.onNode(isToggleable()).performScrollTo().performClick()
            click("Open test wallet")
            waitFor("Your Keys. Your Bitcoin."); capture("02-wallet")
            click("Send"); waitFor("Send XBT"); capture("03-send")
            compose.onNodeWithContentDescription("Back").performClick()
            click("Receive"); click("Create address")
            compose.waitUntil(30_000) { compose.onAllNodesWithContentDescription("Receive QR code").fetchSemanticsNodes().isNotEmpty() }
            capture("04-receive")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithContentDescription("Lightning").performClick(); waitFor("Lightning through Ark"); capture("05-lightning")
            compose.onNodeWithContentDescription("Activity").performClick(); waitFor("No activity loaded"); capture("06-activity")
            compose.onNodeWithContentDescription("Settings").performClick(); waitFor("Your wallet"); capture("07-settings-dark")
            click("Connection settings"); waitFor("Save and connect"); capture("08-connections")
            compose.onNodeWithContentDescription("Back").performClick()
            click("Light"); compose.onNodeWithText("Your wallet").performScrollTo(); capture("09-settings-light")
            compose.onNodeWithContentDescription("Wallet").performClick(); capture("10-wallet-light")
        }
    }
}
