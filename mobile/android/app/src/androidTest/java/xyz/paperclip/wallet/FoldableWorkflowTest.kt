package xyz.paperclip.wallet

import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertSame
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Run only in the disposable Pixel Fold AVD, before creating any wallet. */
class FoldableWorkflowTest {
	@get:Rule val compose = createEmptyComposeRule()
	private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
	private fun state(value: Int) {
		instrumentation.uiAutomation.executeShellCommand("cmd device_state state $value").close()
		android.os.SystemClock.sleep(1500)
		// Folding can put the cover display to sleep on newer Pixel system images.
		// Wake it as a user would, then wait for the resumed Compose hierarchy.
		instrumentation.uiAutomation.executeShellCommand("input keyevent 224").close()
		compose.waitUntil(15000) {
			runCatching { compose.onAllNodesWithText("Fold test wallet").fetchSemanticsNodes().isNotEmpty() }.getOrDefault(false)
		}
	}
	private fun capture(name: String) {
		instrumentation.waitForIdleSync()
		android.os.SystemClock.sleep(400)
		val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
		File(instrumentation.targetContext.cacheDir, "$name.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
		image.recycle()
	}
	@Test fun coverUnfoldRotateRetainsSetupDraft() {
		assumeTrue(InstrumentationRegistry.getArguments().getString("foldable") == "true")
		val context = instrumentation.targetContext
		ActivityScenario.launch<MainActivity>(Intent(context, MainActivity::class.java).putExtra("regtestScreenshots", true)).use { scenario ->
			var original: MainActivity? = null
			scenario.onActivity { original = it }
			compose.waitUntil(15000) { compose.onAllNodesWithText("Wallet name").fetchSemanticsNodes().isNotEmpty() }
			compose.onNodeWithText("Wallet name").performTextReplacement("Fold test wallet")
			compose.onNodeWithText("Your keys. Your bitcoin.").performClick()
			instrumentation.uiAutomation.executeShellCommand("input keyevent 4").close()
			state(2)
			capture("fold70-open")
			state(0)
			compose.onNodeWithText("Fold test wallet").assertExists()
			capture("fold70-cover")
			state(2)
			compose.onNodeWithText("Fold test wallet").assertExists()
			scenario.onActivity { assertSame(original, it); it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
			compose.waitForIdle()
			compose.onNodeWithText("Fold test wallet").assertExists()
			scenario.onActivity { assertSame(original, it); it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
			compose.onNodeWithText("Connect a hardware wallet").performScrollTo().performClick()
			compose.onNodeWithText("Connect a public wallet").assertExists()
			capture("fold70-public-wallet")
		}
	}
}
