package xyz.paperclip.wallet

import android.content.Context
import android.content.Intent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test

/** Uses only a newly created unfunded profile; restores prior selection/preferences. */
class WalletSettingsScreensTest {
	@get:Rule val compose = createEmptyComposeRule()

	private fun click(text: String) {
		compose.waitUntil(10000) {
			compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
		}
		compose.onNodeWithText(text).performScrollTo().performClick()
	}

	private fun back() {
		compose.waitUntil(10000) {
			compose
				.onAllNodes(hasContentDescription("Back") and isEnabled())
				.fetchSemanticsNodes()
				.isNotEmpty()
		}
		compose.onNodeWithContentDescription("Back").performScrollTo().performClick()
		compose.waitUntil(10000) {
			compose.onAllNodesWithText("Your wallet").fetchSemanticsNodes().isNotEmpty()
		}
	}

	@Test
	fun unitsAddressPagesSecurityAndNoticesAreReachable() {
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		val engine = WalletEngine.shared(context)
		val original = runBlocking { engine.activeID() }
		val preferences = context.getSharedPreferences("appearance", Context.MODE_PRIVATE)
		val oldUnit = preferences.getString("unit", null)
		val created = runBlocking {
			engine.create(engine.phrase(), "xbt-regtest", "Settings UI fixture")
			repeat(25) { engine.call("address_onchain") }
			checkNotNull(engine.activeID())
		}
		try {
			preferences.edit().putString("unit", "SATS").commit()
			ActivityScenario.launch<MainActivity>(
					Intent(context, MainActivity::class.java).putExtra("regtestScreenshots", true),
				)
				.use {
					compose.waitUntil(30000) {
						compose
							.onAllNodesWithText("Your Keys. Your Bitcoin.")
							.fetchSemanticsNodes()
							.isNotEmpty()
					}
					compose.onNodeWithTag("tab-Settings").performClick()
					click("Wallet security")
					compose.onNodeWithText("Require device authentication").assertExists()
					back()
					click("On-chain tools")
					click("Load addresses")
					compose.waitUntil(10000) {
						compose
							.onAllNodesWithText("Next addresses")
							.fetchSemanticsNodes()
							.isNotEmpty()
					}
					compose.onNodeWithText("Previous addresses").assertIsNotEnabled()
					click("Next addresses")
					compose.waitUntil(10000) {
						compose
							.onAllNodes(hasText("Previous addresses") and isEnabled())
							.fetchSemanticsNodes()
							.isNotEmpty()
					}
					back()
					click("Open-source notices")
					compose.waitUntil(10000) {
						compose
							.onAllNodesWithText("Java-WebSocket-MIT.txt", substring = true)
							.fetchSemanticsNodes()
							.isNotEmpty()
					}
					back()
					click("XBT")
					compose.onNodeWithTag("tab-Wallet").performClick()
					click("Send")
					compose.onNodeWithText("Amount in XBT").assertExists()
					compose.onNodeWithText("Amount in XBT").performTextInput("0.00000001")
					compose.onNodeWithText("Review payment").assertIsNotEnabled()
				}
		} finally {
			preferences
				.edit()
				.apply { if (oldUnit == null) remove("unit") else putString("unit", oldUnit) }
				.commit()
			runBlocking {
				engine.removeWallet(
					created,
					"Settings UI fixture",
					"REMOVE Settings UI fixture",
					true,
				)
				if (original != null && engine.profiles().any { it.id == original })
					engine.select(original)
			}
		}
	}
}
