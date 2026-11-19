package xyz.paperclip.wallet

import android.app.Application
import android.provider.MediaStore
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test

/** Presentation states only: no quote, invoice, send or wallet opening. */
class PaymentFlowLayoutTest {
	@get:Rule val compose = createComposeRule()
	@Test fun qrBoardingRequiresExplicitSameNetworkHotRecipient() {
		var selected: Pair<String, String>? = null
		val state = WalletState(activeID = "qr", profiles = listOf(
			WalletProfile("qr", "QR signer", "hardware", "xbt-mainnet"),
			WalletProfile("hot", "Everyday wallet", "hot", "xbt-mainnet"),
			WalletProfile("other", "Other network", "hot", "xbt-regtest"),
			WalletProfile("watch", "Watch only", "watch", "xbt-mainnet")))
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp)) {
				HardwareBoardDestination(state, { source, target -> selected = source to target }, {})
			}
		} } }
		compose.onNodeWithText("Continue to boarding").assertIsNotEnabled()
		compose.onNodeWithText("Other network").assertDoesNotExist()
		compose.onNodeWithText("Watch only").assertDoesNotExist()
		compose.onNodeWithText("Everyday wallet").performClick()
		org.junit.Assert.assertNull(selected)
		compose.onNodeWithText("Continue to boarding").performScrollTo().performClick()
		compose.runOnIdle { org.junit.Assert.assertEquals("qr" to "hot", selected) }
		compose.onNodeWithText("Confirm and board").assertDoesNotExist()
	}
	@Test fun boardingRetainsQrSourceAndOffersConnectionBeforeReview() {
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		val model = WalletModel(context.applicationContext as Application)
		val state = WalletState(activeID = "hot", hardwareBoardSourceID = "qr", profiles = listOf(
			WalletProfile("qr", "QR signer", "hardware", "xbt-mainnet"),
			WalletProfile("hot", "Everyday wallet", "hot", "xbt-mainnet")))
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp)) {
				HardwarePayment(state, model, boarding = true)
			}
		} } }
		compose.onNodeWithText("QR signer").assertIsSelected()
		compose.onNodeWithText("XBT address").assertDoesNotExist()
		compose.onNodeWithText("Connect wallet").performScrollTo().assertIsDisplayed().assertIsEnabled()
		compose.onNodeWithText("Review boarding").assertIsNotEnabled()
		compose.onNodeWithText("Confirm and board").assertDoesNotExist()
	}
	@Test fun savedSendShowsLatestReplacementWithoutReplayControls() {
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		val model = WalletModel(context.applicationContext as Application)
		val original = "ab".repeat(32)
		val replacement = "cd".repeat(32)
		val result = org.json.JSONObject().put("state", "unknown").put("amount_sat", 12000)
			.put("txid", original).put("replacement_txids", org.json.JSONArray().put(replacement))
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp)) {
				Send(WalletState(connected = true, result = result), model)
			}
		} } }
		compose.onNodeWithText("Amount").assertExists()
		compose.onNodeWithText(replacement).assertIsDisplayed()
		compose.onNodeWithText(original).assertDoesNotExist()
		compose.onNodeWithText("Check payment status").assertIsDisplayed().assertIsEnabled()
		compose.onNodeWithText("Review payment").assertDoesNotExist()
		compose.onNodeWithText("Confirm and send").assertDoesNotExist()
		val instrumentation = InstrumentationRegistry.getInstrumentation()
		// Compose semantics remain accessible behind an emulator crash dialog.
		// Require the actual app window before accepting visual evidence.
		compose.waitUntil(10_000) {
			instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString() == context.packageName
		}
		compose.waitForIdle()
		instrumentation.waitForIdleSync()
		val screenshot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
		try {
			val values = android.content.ContentValues().apply {
				put(MediaStore.Images.Media.DISPLAY_NAME, "saved-send-recovery.png")
				put(MediaStore.Images.Media.MIME_TYPE, "image/png")
				put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/PaperclipPreview")
				put(MediaStore.Images.Media.IS_PENDING, 1)
			}
			val resolver = context.contentResolver
			val uri = checkNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
			checkNotNull(resolver.openOutputStream(uri)).use {
				check(screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
			}
			resolver.update(uri, android.content.ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
		} finally {
			screenshot.recycle()
		}
	}
	@Test fun unknownReceiptKeepsFullAmountAndShareReachableWithLargeText() {
		var fontScale by mutableStateOf(1f)
		var shared = 0
		var closed = 0
		val item = WalletActivity("a".repeat(64), "On-chain send", "unknown", -2100000000000000L, null, false)
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) {
			val density = androidx.compose.ui.platform.LocalDensity.current
			CompositionLocalProvider(androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(density.density, fontScale)) {
				Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
					ActivityReceiptPage(item, BitcoinUnit.SATS, null, { shared++ }, null, { closed++ })
				}
			}
		} }
		compose.onNodeWithText(BitcoinUnit.SATS.display(item.amount)).assertExists()
		compose.onNodeWithText("Recipient receives").assertDoesNotExist()
		compose.waitForIdle()
		val instrumentation = InstrumentationRegistry.getInstrumentation()
		val screenshot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
		java.io.File(instrumentation.targetContext.cacheDir, "activity-receipt.png").outputStream().use {
			screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
		}
		screenshot.recycle()
		compose.onNodeWithText("Confirmation has not been verified. Check Activity before sending again.").performScrollTo().assertIsDisplayed()
		compose.onNodeWithText("View in explorer").assertDoesNotExist()
		compose.runOnIdle { fontScale = 2f }
		compose.onNodeWithText(BitcoinUnit.SATS.display(item.amount)).performScrollTo().assertIsDisplayed()
		compose.onNodeWithText("Share receipt").performScrollTo().assertIsDisplayed().performClick()
		compose.onNodeWithText("Done").assertIsDisplayed().performClick()
		compose.runOnIdle { check(shared == 1 && closed == 1) }
	}
	@Test fun reviewReplacesDraftAndReturningKeepsRecipient() {
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		val model = WalletModel(context.applicationContext as Application)
		var state by mutableStateOf(WalletState(connected = true))
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp)) { Send(state, model) }
		} } }
		compose.onNodeWithText("Address, invoice or offer").performTextInput("sample-recipient")
		compose.runOnIdle { state = state.copy(review = PaymentReview("sample-recipient", 1000, 10, 1010, true, 0), busy = true) }
		compose.onNodeWithText("Address, invoice or offer").assertDoesNotExist()
		compose.onNodeWithText("Confirm and send").assertIsDisplayed().assertIsNotEnabled()
		compose.runOnIdle { state = state.copy(review = null, busy = false) }
		compose.onNodeWithText("Address, invoice or offer").assertTextContains("sample-recipient")
		compose.onNodeWithText("Confirm and send").assertDoesNotExist()
	}
	@Test fun nodeReviewKeepsInvoicePrivateUntilExpandedAndGuardsConfirmation() {
		var review by mutableStateOf(NodeInvoiceReview("synthetic-invoice", "fixture", 10_000_000, Long.MAX_VALUE, 100))
		var busy by mutableStateOf(true)
		var confirmations = 0
		var edits = 0
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp)) {
				NodePaymentReview(review, BitcoinUnit.SATS, busy, { confirmations++ }, { edits++ })
			}
		} } }
		compose.onNodeWithText("Confirm and pay").assertIsDisplayed().assertIsNotEnabled()
		compose.onNodeWithText("synthetic-invoice").assertDoesNotExist()
		compose.onNodeWithText("View full invoice").performClick()
		compose.onNodeWithText("synthetic-invoice").assertIsDisplayed()
		compose.runOnIdle { busy = false; review = review.copy(expires = 0) }
		compose.onNodeWithText("Confirm and pay").assertIsNotEnabled()
		compose.runOnIdle { review = review.copy(expires = Long.MAX_VALUE) }
		compose.onNodeWithText("Confirm and pay").assertIsEnabled().performClick()
		compose.onNodeWithText("Edit invoice or fee").performClick()
		compose.runOnIdle { org.junit.Assert.assertEquals(1, confirmations); org.junit.Assert.assertEquals(1, edits) }
	}

	@Test fun generatedRequestReplacesSetupWithoutIssuingAnother() {
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		val model = WalletModel(context.applicationContext as Application)
		var state by mutableStateOf(WalletState(address = "sample-request-no-live-funds"))
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp)) { Receive(state, model, "On-chain") }
		} } }
		compose.onNodeWithText("Create address").assertDoesNotExist()
		compose.onNodeWithContentDescription("Receive QR code").assertIsDisplayed()
		compose.onNodeWithText("Copy").assertIsDisplayed()
		compose.onNodeWithText("Share").assertIsDisplayed()
		compose.onNodeWithText("sample-request-no-live-funds").assertDoesNotExist()
		compose.onNodeWithText("View full address or request").performClick()
		compose.onNodeWithText("sample-request-no-live-funds").assertExists()
		compose.runOnIdle { state = state.copy(address = "") }
		compose.onNodeWithText("Create address").assertIsDisplayed()
		compose.onNodeWithContentDescription("Receive QR code").assertDoesNotExist()
	}
}
