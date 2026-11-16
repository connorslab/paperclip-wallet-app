package xyz.paperclip.wallet

import android.app.Application
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
