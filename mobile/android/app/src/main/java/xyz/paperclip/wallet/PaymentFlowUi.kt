package xyz.paperclip.wallet

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material3.Icon
import androidx.compose.ui.Alignment
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/** Only the current step is composed. Never retain outgoing payment controls. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun PaymentStage(steps: List<String>, current: Int, content: @Composable ColumnScope.() -> Unit) {
	val entrance = remember { Animatable(1f) }
	LaunchedEffect(current) {
		entrance.snapTo(0f)
		// Compose's motion duration scale also honors disabled system animations.
		entrance.animateTo(1f, tween(180))
	}
	Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
		FlowRow(Modifier.semantics { contentDescription = "Step ${current + 1} of ${steps.size}: ${steps[current]}" },
			horizontalArrangement = Arrangement.spacedBy(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
			steps.forEachIndexed { index, label ->
				Text("${index + 1}  $label", style = MaterialTheme.typography.labelMedium,
					color = if (current == index) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
			}
		}
		Column(Modifier.fillMaxWidth().graphicsLayer {
			alpha = .65f + .35f * entrance.value
			translationY = 8.dp.toPx() * (1f - entrance.value)
		}, verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
	}
}

/** The arrow animates once when reviewing; completion uses a separate receipt. */
@Composable
internal fun ReviewAmountHero(amount: String, source: String) {
	val entrance = remember { Animatable(0f) }
	LaunchedEffect(Unit) { entrance.animateTo(1f, spring(dampingRatio = .7f, stiffness = 500f)) }
	Column(Modifier.fillMaxWidth().padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally,
		verticalArrangement = Arrangement.spacedBy(14.dp)) {
		Icon(Icons.Default.NorthEast, null, Modifier.graphicsLayer {
			rotationZ = -12f * (1f - entrance.value)
			scaleX = .8f + .2f * entrance.value; scaleY = scaleX
		}.size(60.dp).background(MaterialTheme.colorScheme.primary.copy(alpha = .12f), CircleShape).padding(16.dp),
			tint = MaterialTheme.colorScheme.primary)
		Text("Recipient receives", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
		Text(amount, style = MaterialTheme.typography.headlineLarge, textAlign = TextAlign.Center)
		Text("From $source", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
	}
}
