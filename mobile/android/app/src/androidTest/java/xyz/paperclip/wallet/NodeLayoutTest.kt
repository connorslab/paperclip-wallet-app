package xyz.paperclip.wallet

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Real node editor with an unloaded model. Never reads saved node credentials. */
class NodeLayoutTest {
	@get:Rule val compose = createComposeRule()
	@Test fun bothNodeEditorsRenderAndRetainEndpointDraft() {
		val instrumentation = InstrumentationRegistry.getInstrumentation()
		val model = LightningModel(instrumentation.targetContext.applicationContext as Application)
		compose.setContent {
			MaterialTheme(colorScheme = darkColorScheme(primary = Color(0xffff7538), background = Color(0xff101c2d), surface = Color(0xff1d3046))) {
				Surface {
					Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
						Text("Lightning", style = MaterialTheme.typography.headlineLarge)
						NodeLightning(model, initialPage = "connection")
					}
				}
			}
		}
		compose.onNodeWithText("REST address").performTextInput("https://test-node.invalid:8180")
		compose.onNodeWithText("CLN").performClick()
		compose.onNodeWithText("Rune").assertExists()
		compose.onNodeWithText("test-node.invalid", substring = true).assertExists()
		compose.onNodeWithText("LND").performClick()
		compose.onNodeWithText("Macaroon (hex)").assertExists()
		instrumentation.uiAutomation.executeShellCommand("input keyevent 4").close()
		compose.waitForIdle()
		android.os.SystemClock.sleep(500)
		val screenshot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
		File(instrumentation.targetContext.cacheDir, "fold70-node.png").outputStream().use { screenshot.compress(Bitmap.CompressFormat.PNG, 100, it) }
		screenshot.recycle()
	}
}
