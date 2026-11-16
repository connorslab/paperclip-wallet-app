package xyz.paperclip.wallet

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
