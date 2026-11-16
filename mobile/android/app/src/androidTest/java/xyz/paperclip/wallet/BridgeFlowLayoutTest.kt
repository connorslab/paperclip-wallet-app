package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Only presentation callbacks. No wallet, bridge or node is opened. */
class BridgeFlowLayoutTest {
	@get:Rule val compose = createComposeRule()
	private fun screenshot(name: String) {
		compose.waitForIdle()
		val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
		val resolver = instrumentation.targetContext.contentResolver
		val values = android.content.ContentValues().apply {
			put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
			put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png")
			put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/PaperclipPreview")
			put(android.provider.MediaStore.Images.Media.IS_PENDING, 1)
		}
		val uri = checkNotNull(resolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
		val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
		checkNotNull(resolver.openOutputStream(uri)).use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
		image.recycle()
		resolver.update(uri, android.content.ContentValues().apply { put(android.provider.MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
	}
	private fun record(hash: String, amount: Int, receive: Boolean = false) = JSONObject()
		.put("hash", hash).put("receive", receive).put("source", "ark").put("target", "synthetic-recipient")
		.put("submitted", receive).put("quote", JSONObject().put("sat", amount).put("pay_sat", 250)
			.put("hold_invoice", "synthetic-unfunded-invoice").put("expires_at", System.currentTimeMillis() / 1000 + 3600))

	@Test fun entryReviewAndHistoryStaySeparateAndNeverFundFromNavigation() {
		val old = record("01".repeat(32), 100).put("submitted", true)
		val newest = record("02".repeat(32), 200)
		var state by mutableStateOf(BridgeState(history = listOf(old)))
		var sends = 0; var quotes = 0; var checks = 0; var checked = ""
		var scale by mutableFloatStateOf(1f)
		compose.setContent {
			val density = LocalDensity.current
			CompositionLocalProvider(LocalDensity provides Density(density.density, scale)) {
				MaterialTheme(colorScheme = darkColorScheme(primary = androidx.compose.ui.graphics.Color(0xfff56835), background = androidx.compose.ui.graphics.Color(0xff111c2e), surface = androidx.compose.ui.graphics.Color(0xff111c2e))) {
					Surface { Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp)) {
						BridgeContent(state, true, { BridgeStatusLabel(BridgeHealthState.LIVE) },
							onQuote = { invoice, source, receive, _, _ ->
								assertEquals("synthetic-recipient", invoice); assertEquals("ark", source); assertFalse(receive); quotes++
								state = state.copy(record = newest, history = listOf(newest, old), quoteRevision = 1,
									nativeQuote = JSONObject().put("fee_sat", 10).put("total_sat", 260))
							}, onFund = { sends++ }, onCheck = { checks++; checked = state.record!!.getString("hash") },
							onSaveKey = { fail("Access settings must not run during navigation") },
							onSelect = { hash -> state = state.copy(record = state.history.first { it.getString("hash") == hash }, nativeQuote = null, nodeReview = null) })
					} }
				}
			}
		}
		compose.onNodeWithText("Private API key (optional)").assertDoesNotExist()
		compose.onNodeWithText("Confirm and fund bridge").assertDoesNotExist()
		screenshot("bridge-entry")
		compose.onNodeWithText("Pay Spamcoin (BTC)").performClick()
		compose.onNodeWithText("Spamcoin (BTC) invoice").performTextInput("synthetic-recipient")
		compose.onNodeWithText("Ark balance").performClick()
		compose.onNodeWithText("Review conversion").performScrollTo().performClick()
		compose.onNodeWithText("Payment details").assertExists()
		compose.onNodeWithText("Confirm and fund bridge").performScrollTo().assertIsEnabled()
		assertEquals(1, quotes); assertEquals(0, sends)
		compose.onNodeWithText("Payment details").performScrollTo(); screenshot("bridge-review-compact")
		compose.onNodeWithText("Back to bridge").performScrollTo().performClick()
		compose.onNodeWithText("Bridge activity").performScrollTo().performClick()
		compose.onNodeWithText("Pay 100 BTC sats").performScrollTo().performClick()
		compose.onNodeWithText("Confirm and fund bridge").assertDoesNotExist()
		compose.onNodeWithText("Check saved payment").performScrollTo().performClick()
		assertEquals(old.getString("hash"), checked); assertEquals(1, checks); assertEquals(0, sends)
		compose.onNodeWithText("Back to bridge").performScrollTo().performClick()
		compose.onNodeWithText("Bridge activity").performScrollTo().performClick()
		compose.onNodeWithText("Pay 200 BTC sats").performScrollTo().performClick()
		compose.onNodeWithText("Confirm and fund bridge").assertDoesNotExist()
		compose.onNodeWithText("Review again").performScrollTo().assertIsEnabled()
		compose.onNodeWithText("Back to bridge").performScrollTo().performClick()
		compose.runOnIdle { scale = 2f }
		compose.onNodeWithText("Receive XBT").performScrollTo().assertIsDisplayed()
		compose.onNodeWithText("Bridge activity").performScrollTo().assertIsDisplayed()
		screenshot("bridge-home-large-text")
		assertEquals(0, sends)
	}

	@Test fun incomingHistoryNeverOffersToFundOrShowsAnExpiredQr() {
		val incoming = record("03".repeat(32), 300, true).also { it.getJSONObject("quote").put("expires_at", 1) }
		var state by mutableStateOf(BridgeState(history = listOf(incoming)))
		compose.setContent { MaterialTheme { Column(Modifier.verticalScroll(rememberScrollState())) {
			BridgeContent(state, false, { BridgeStatusLabel(BridgeHealthState.UNKNOWN) },
				{ _, _, _, _, _ -> fail("History must not request another quote") },
				{ fail("Incoming bridge cannot fund a payment") }, {}, {},
				{ state = state.copy(record = incoming) })
		} } }
		compose.onNodeWithText("Bridge activity").performScrollTo().performClick()
		compose.onNodeWithText("Receive 300 XBT sats").performScrollTo().performClick()
		compose.onNodeWithText("Confirm and fund bridge").assertDoesNotExist()
		compose.onNodeWithText("Copy BTC invoice").assertDoesNotExist()
		compose.onNodeWithContentDescription("Receive QR code").assertDoesNotExist()
		compose.onNodeWithText("Check saved payment").performScrollTo().assertIsEnabled()
	}
}
