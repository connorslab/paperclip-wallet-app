package xyz.paperclip.wallet

import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Synthetic session only: no transport, wallet keys or funds. */
class JoinBlaketLayoutTest {
	@get:Rule val compose = createComposeRule()
	@Test fun compactJarSelectionShowsActionsAndKeepsAllAccountsReachable() {
		val state = JoinBlaketUiState().apply {
			wallet.value = "Sample Jars wallet · no live funds"
			session.value = JSONObject().put("session", true).put("maker_running", false)
				.put("coinjoin_in_process", false).put("rescanning", false)
			jars.value = listOf("Apricot", "Blueberry", "Cherry", "Date", "Elderberry").mapIndexed { id, name ->
				JSONObject().put("id", id).put("name", name).put("total_sat", if (id == 0) 200000 else 0)
					.put("confirmed_sat", if (id == 0) 200000 else 0).put("pending_sat", 0)
					.put("frozen_sat", 0).put("bond_sat", 0)
			}
		}
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface(color = MaterialTheme.colorScheme.background) {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
				androidx.compose.material3.Text("Jars", style = MaterialTheme.typography.headlineLarge)
				JoinBlaketPage(state)
			}
		} } }
		compose.onNodeWithTag("jar-0").assertIsSelected()
		for (id in 0..4) compose.onNodeWithTag("jar-$id").assertIsDisplayed()
		val first = compose.onNodeWithTag("jar-0").fetchSemanticsNode().boundsInRoot
		val second = compose.onNodeWithTag("jar-1").fetchSemanticsNode().boundsInRoot
		val last = compose.onNodeWithTag("jar-4").fetchSemanticsNode().boundsInRoot
		assertEquals(first.top, second.top, 2f)
		assertEquals((first.left + second.right) / 2, last.center.x, 2f)
		assertEquals(first.width, last.width, 2f)
		compose.waitForIdle()
		val instrumentation = InstrumentationRegistry.getInstrumentation()
		instrumentation.waitForIdleSync()
		val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
		File(instrumentation.targetContext.getExternalFilesDir(null), "android-jars.png").outputStream().use {
			image.compress(Bitmap.CompressFormat.PNG, 100, it)
		}
		compose.onNodeWithTag("jar-4").performClick().assertIsSelected()
		compose.onNodeWithText("Receive into Elderberry").assertExists()
		compose.runOnIdle { assertEquals(4, state.selected.intValue); assertNull(state.client.value) }
	}

	@Test fun bondReviewNamesWalletAndDateWithoutFunding() {
		val state = JoinBlaketUiState().apply {
			wallet.value = "Fixture Jars wallet"
			session.value = JSONObject().put("session", true).put("maker_running", false)
				.put("coinjoin_in_process", false).put("rescanning", false)
			bondMonth.value = "2099-12"
		}
		compose.setContent { MaterialTheme { Surface {
			Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) { JoinBlaketPage(state) }
		} } }
		compose.onNodeWithText("Set up a fidelity bond").performScrollTo().performClick()
		compose.onNodeWithText("Review bond address").performScrollTo().performClick()
		compose.onNodeWithText("Create bond address?").assertIsDisplayed()
		compose.onNodeWithText("Wallet: Fixture Jars wallet. Coins sent here will be locked until 2099-12-01 at 00:00 UTC. Creating the address sends no funds. Review the amount and mining fee separately when funding. Earnings are not guaranteed.").assertIsDisplayed()
		compose.onNodeWithText("Cancel").performClick()
		compose.onNodeWithText("Create bond address?").assertDoesNotExist()
		compose.runOnIdle {
			assertNull(state.client.value)
			assertNull(state.bondAddress.value)
			state.bondMonth.value = "2020-01"
		}
		compose.onNodeWithText("Review bond address").performScrollTo().performClick()
		compose.onNodeWithText("Choose a future month before 2100. Bonds unlock on its first day at 00:00 UTC.").performScrollTo().assertIsDisplayed()
	}
}
