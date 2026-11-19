package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Synthetic presentation only: no wallet, bridge registration or payment. */
class ReusableBridgeLayoutTest {
    @get:Rule val compose = createComposeRule()
    @Test fun reviewAndRevocationRemainExplicit() {
        var state by mutableStateOf(ReusableBridgeState(loaded = true, available = true))
        var creates = 0; var revocations = 0
        val destination = "lno1pg89qctsv4exxmrfwqs8getnwsxyzqgqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq93pqfumuen7l8wthtz45p3ftn58pvrs9xlumvkuu2xet8egzkcklqtes"
        val row = JSONObject().put("id", "fixture").put("token", "ab".repeat(32)).put("xbt", true)
            .put("destination", destination).put("revocation_requested", false)
            .put("binding", JSONObject().put("offer", "lno1pg89qctsv4exxmrfwqs8getnwstzzqnehen8a7wuhwk9tgrzjh8gwzc8q2dlekedec5djk0js9d3d7qhnq").put("direction", "toBLAKE2b").put("revoked", false))
        compose.setContent {
            MaterialTheme(colorScheme = paperclipColors(true)) {
                Surface { Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp)) {
                    ReusableBridgeContent(state, onPayOffer = { _, _ -> fail("Receive offer must not initiate payment") },
                        onBack = {}, onCreate = { offer, xbt -> assertEquals(destination,offer); assertTrue(xbt); creates++; state = state.copy(rows = listOf(row)) },
                        onRestore = { fail("Unexpected restore") }, onAction = { saved, action -> assertEquals("revoke",action); assertEquals("fixture",saved.getString("id")); revocations++; state = state.copy(rows = listOf(JSONObject(row.toString()).put("revocation_requested",true))) }, onNode = {})
                } }
            }
        }
        compose.onNodeWithText("Receiving wallet’s amountless BOLT12 offer").performTextInput(destination)
        compose.onNodeWithText("Review offer").performScrollTo().performClick()
        compose.onNodeWithText("Review receiving wallet").performScrollTo().assertIsDisplayed()
        assertEquals(0,creates)
        screenshot("reusable-review-android")
        compose.onNodeWithText("Create reusable offer").performScrollTo().performClick()
        assertEquals(1,creates)
        compose.onNodeWithText("Reusable offer", substring = false).performScrollTo().performClick()
        compose.onNodeWithText("Saved offer").performScrollTo().assertIsDisplayed()
        screenshot("reusable-share-android")
        compose.onNodeWithText("Revoke offer").performScrollTo().performClick()
        compose.onNodeWithText("Stop new payments?").assertIsDisplayed(); assertEquals(0,revocations)
        compose.onNodeWithText("Cancel").performClick(); assertEquals(0,revocations)
        compose.onNodeWithText("Revoke offer").performScrollTo().performClick()
        compose.onAllNodesWithText("Revoke offer").onLast().performClick()
        compose.onNodeWithText("Revocation not confirmed · sharing disabled").performScrollTo().assertIsDisplayed()
        assertEquals(1,revocations)
    }
    private fun screenshot(name: String) {
        compose.waitForIdle()
        val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        val resolver = instrumentation.targetContext.contentResolver
        val values = android.content.ContentValues().apply {
            put(android.provider.MediaStore.Images.Media.DISPLAY_NAME,"$name.png")
            put(android.provider.MediaStore.Images.Media.MIME_TYPE,"image/png")
            put(android.provider.MediaStore.Images.Media.RELATIVE_PATH,"Pictures/PaperclipPreview")
        }
        val uri = checkNotNull(resolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,values))
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        checkNotNull(resolver.openOutputStream(uri)).use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) }; bitmap.recycle()
    }
}
