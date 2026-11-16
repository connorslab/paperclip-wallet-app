package xyz.paperclip.wallet

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Never generates words, starts sensor capture, or creates a wallet. */
class SeedGenerationLayoutTest {
	@get:Rule val compose = createComposeRule()

	@Test fun sourcesRemainReachableAndCannotGenerateWithoutInput() {
		val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
		val model = WalletModel(app)
		var cancelled = false
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) {
			SeedGenerationDialog(model) { cancelled = true }
		} }
		compose.onNodeWithText("Generate 24 words").assertIsEnabled()
		for (source in listOf("Dice", "Sensors")) {
			compose.onNodeWithText(source).performScrollTo().performClick()
			compose.onNodeWithText("Generate 24 words").assertIsNotEnabled()
		}
		compose.onNodeWithText("System").performScrollTo().performClick()
		compose.onNodeWithText("Generate 24 words").assertIsEnabled()
		compose.onNodeWithText("12 words").performScrollTo().performClick()
		compose.onNodeWithText("Generate 12 words").assertIsEnabled()
		compose.onNodeWithText("Cancel").performScrollTo().performClick()
		compose.runOnIdle { assertTrue(cancelled) }
	}
}
