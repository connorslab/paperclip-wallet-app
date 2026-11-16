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
