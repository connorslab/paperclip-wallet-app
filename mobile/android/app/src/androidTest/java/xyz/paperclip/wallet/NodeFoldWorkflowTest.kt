package xyz.paperclip.wallet

import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertSame
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Run after WalletScreensTest in the disposable Fold AVD. Saved credentials are not loaded. */
class NodeFoldWorkflowTest {
	@get:Rule val compose = createEmptyComposeRule()
	@Test fun nodeDraftSurvivesCoverScreenAndRotation() {
		assumeTrue(InstrumentationRegistry.getArguments().getString("foldable") == "true")
		val instrumentation = InstrumentationRegistry.getInstrumentation()
		val context = instrumentation.targetContext
		assumeTrue(runBlocking { WalletEngine.shared(context).network() } == "xbt-regtest")
		fun posture(value: Int) {
			instrumentation.uiAutomation.executeShellCommand("cmd device_state state $value").close()
			android.os.SystemClock.sleep(1500)
			compose.waitForIdle()
		}
		ActivityScenario.launch<MainActivity>(Intent(context, MainActivity::class.java).putExtra("regtestScreenshots", true)).use { scenario ->
			var original: MainActivity? = null
			scenario.onActivity { original = it }
			compose.waitUntil(15000) { compose.onAllNodes(hasTestTag("tab-Lightning") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
			compose.onNodeWithTag("tab-Lightning").performClick()
			compose.waitUntil(10000) { compose.onAllNodesWithText("Node connection").fetchSemanticsNodes().isNotEmpty() }
			compose.onNodeWithText("Node connection").performScrollTo().performClick()
			compose.onNodeWithText("REST address").performTextInput("https://test-node.invalid:8180")
			instrumentation.uiAutomation.executeShellCommand("input keyevent 4").close()
			posture(0)
			compose.onNodeWithText("test-node.invalid", substring = true).assertExists()
			posture(2)
			compose.onNodeWithText("test-node.invalid", substring = true).assertExists()
			scenario.onActivity { assertSame(original, it); it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
			android.os.SystemClock.sleep(1000)
			compose.onNodeWithText("test-node.invalid", substring = true).assertExists()
			scenario.onActivity { assertSame(original, it); it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
			compose.onNodeWithText("REST address").performScrollTo()
			compose.waitForIdle()
			android.os.SystemClock.sleep(500)
			val screenshot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
			File(context.cacheDir, "fold70-node-app.png").outputStream().use { screenshot.compress(Bitmap.CompressFormat.PNG, 100, it) }
			screenshot.recycle()
		}
	}
}
