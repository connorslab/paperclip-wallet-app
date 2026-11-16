package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Rule
import org.junit.Test

class BridgeHealthLayoutTest {
	@get:Rule val compose = createComposeRule()
	@Test fun availabilityLabelsRemainReadableWithLargeText() {
		compose.setContent {
			val density = LocalDensity.current
			CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
				MaterialTheme(colorScheme = darkColorScheme()) {
					Surface {
						Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
							BridgeHealthState.entries.forEach { BridgeStatusLabel(it) }
						}
					}
				}
			}
		}
		BridgeHealthState.entries.forEach { state ->
			compose.onNodeWithContentDescription("Bridge service: ${state.title}. Service availability, not payment status.").assertIsDisplayed()
		}
	}
}
