package xyz.paperclip.wallet

import android.content.Intent
import android.content.ContentValues
import android.graphics.Bitmap
import android.provider.MediaStore
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test

/** Runs against the actual JNI engine, without any mock wallet balances. */
class WalletScreensTest {
    @get:Rule val compose = createEmptyComposeRule()
    private fun capture(name: String) {
        compose.waitForIdle()
        // Allow the Android render thread to present the settled Compose frame.
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        android.os.SystemClock.sleep(600)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        // Public test images survive the test runner's automatic APK uninstall.
        val resolver = instrumentation.targetContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/PaperclipPreview")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = checkNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
        checkNotNull(resolver.openOutputStream(uri)).use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
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
            waitFor("I wrote down every word")
            capture("00-disposable-regtest-seed")
            val words = (0 until 24).map { index ->
                compose.onNodeWithTag("seed-word-$index", useUnmergedTree = true).fetchSemanticsNode()
                    .config[androidx.compose.ui.semantics.SemanticsProperties.Text].first().text
            }
            click("I wrote down every word")
            compose.onNodeWithText("Verify and create wallet").assertIsNotEnabled()
            compose.onNodeWithTag("seed-confirmation").performTextInput("wrong words")
            compose.onNodeWithText("Verify and create wallet").assertIsNotEnabled()
            compose.onNodeWithTag("seed-confirmation").performTextReplacement(words.joinToString(" "))
            click("Verify and create wallet")
            waitFor("Your Keys. Your Bitcoin."); capture("02-wallet")
            click("Send"); waitFor("Send XBT"); capture("03-send")
            compose.onNodeWithContentDescription("Back").performClick()
            click("Receive"); click("Create address")
            compose.waitUntil(30_000) { compose.onAllNodesWithContentDescription("Receive QR code").fetchSemanticsNodes().isNotEmpty() }
            capture("04-receive")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithTag("tab-Lightning").performClick(); waitFor("Lightning through Ark"); capture("05-lightning")
            compose.onNodeWithTag("tab-Activity").performClick(); waitFor("No activity loaded"); capture("06-activity")
            compose.onNodeWithTag("tab-Settings").performClick(); waitFor("Your wallet"); capture("07-settings-dark")
            click("Connection settings"); waitFor("Save and connect"); capture("08-connections")
            compose.onNodeWithContentDescription("Back").performClick()
            click("Light"); compose.onNodeWithText("Your wallet").performScrollTo(); capture("09-settings-light")
            compose.onNodeWithTag("tab-Wallet").performClick(); capture("10-wallet-light")
        }
    }
}
