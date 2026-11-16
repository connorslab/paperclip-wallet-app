package xyz.paperclip.wallet

import android.app.Application
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** UI only. The report button never opens a wallet or contacts a backend. */
class WalletHealthLayoutTest {
    @get:Rule val compose = createComposeRule()
    @Test fun healthReportReflowsAndExcludesIdentity() {
        var width by mutableStateOf(360)
        var scale by mutableStateOf(1f)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = WalletModel(context.applicationContext as Application)
        val state = WalletState(activeID="PRIVATE-ID", profiles=listOf(WalletProfile("PRIVATE-ID", "PRIVATE-NAME", "hot", "xbt-regtest")), network="xbt-regtest")
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(1f, scale)) {
                MaterialTheme { Column(Modifier.requiredWidth(width.dp).verticalScroll(rememberScrollState())) { WalletHealthPage(state, model) {} } }
            }
        }
        compose.onNodeWithText("Prepare support report").performScrollTo().performClick()
        val report = compose.onNode(hasText("Paperclip support report v1", substring=true))
        report.assertExists()
        compose.onNodeWithText("Share report…").performScrollTo().assertIsDisplayed()
        compose.runOnIdle { width=840 }
        compose.onNodeWithText("Current wallet").performScrollTo()
        val current = compose.onNodeWithText("Current wallet").fetchSemanticsNode().boundsInRoot
        val recovery = compose.onNodeWithText("Recovery readiness").fetchSemanticsNode().boundsInRoot
        assertTrue(recovery.left > current.right)
        compose.runOnIdle { scale=1.6f }
        compose.onNodeWithText("Share report…").performScrollTo().assertIsDisplayed()
        val text = report.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.Text].joinToString()
        assertFalse(text.contains("PRIVATE"))
        assertTrue(text.contains("not recently verified"))
    }
}
