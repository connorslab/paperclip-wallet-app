package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Public form fixtures: no wallet, credential or network access. */
class AdaptiveLayoutTest {
	@get:Rule val compose = createComposeRule()

	@Test fun resizingPreservesDraftAndLargeTextStacksColumns() {
		var width by mutableStateOf(360)
		var fontScale by mutableStateOf(1f)
		val bounds = mutableMapOf<String, Rect>()
		compose.setContent {
			CompositionLocalProvider(LocalDensity provides Density(1f, fontScale)) {
				MaterialTheme {
					Box(Modifier.requiredWidth(width.dp)) {
						WalletColumns(primary = {
							var draft by remember { mutableStateOf("") }
							OutlinedTextField(draft, { draft = it }, Modifier.fillMaxWidth().testTag("draft").onGloballyPositioned { bounds["first"] = it.boundsInWindow() })
						}, secondary = {
							Text("Privacy & verification", Modifier.fillMaxWidth().onGloballyPositioned { bounds["second"] = it.boundsInWindow() })
						})
					}
				}
			}
		}
		compose.onNodeWithTag("draft").performTextInput("my-node.invalid")
		compose.runOnIdle { assertTrue(bounds.getValue("second").top >= bounds.getValue("first").bottom); width = 900 }
		compose.waitForIdle()
		compose.runOnIdle { assertEquals(bounds.getValue("first").top, bounds.getValue("second").top, 1f); fontScale = 1.6f }
		compose.waitForIdle()
		compose.runOnIdle { assertTrue(bounds.getValue("second").top >= bounds.getValue("first").bottom); width = 360 }
		compose.onNodeWithTag("draft").assertTextEquals("my-node.invalid")
	}

	@Test fun columnsAndActionsAvoidSeparatingHinge() {
		val bounds = mutableMapOf<String, Rect>()
		compose.setContent {
			CompositionLocalProvider(LocalDensity provides Density(1f), LocalWalletFold provides FoldBounds(430, 0, 470, 1000, true)) {
				MaterialTheme {
					Column(Modifier.requiredWidth(900.dp)) {
						WalletColumns(primary = {
							Text("Connection", Modifier.fillMaxWidth().onGloballyPositioned { bounds["left"] = it.boundsInWindow() })
						}, secondary = {
							Text("Privacy", Modifier.fillMaxWidth().onGloballyPositioned { bounds["right"] = it.boundsInWindow() })
						})
						HingeSafeContent { Button({}, Modifier.fillMaxWidth().onGloballyPositioned { bounds["action"] = it.boundsInWindow() }) { Text("Verify connection") } }
					}
				}
			}
		}
		compose.waitForIdle()
		compose.runOnIdle {
			assertTrue(bounds.getValue("left").right <= 430)
			assertTrue(bounds.getValue("right").left >= 470)
			val action = bounds.getValue("action")
			assertTrue(action.right <= 430 || action.left >= 470)
		}
	}

	@Test fun tabletopKeepsContentInOneUnobstructedPane() {
		var content: Rect? = null
		compose.setContent {
			CompositionLocalProvider(LocalDensity provides Density(1f), LocalWalletFold provides FoldBounds(0, 400, 1000, 440, false)) {
				Box(Modifier.requiredSize(900.dp, 900.dp)) {
					FoldAwareFrame(allowColumns = true) { Box(Modifier.fillMaxSize().onGloballyPositioned { content = it.boundsInWindow() }) }
				}
			}
		}
		compose.waitForIdle()
		compose.runOnIdle { assertTrue(checkNotNull(content).top >= 440 || checkNotNull(content).bottom <= 400) }
	}
}
