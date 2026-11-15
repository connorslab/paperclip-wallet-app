package xyz.paperclip.wallet

import android.animation.ValueAnimator
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.sin

/** Decorative and finite. Call only after the payment's verified terminal success. */
@Composable
internal fun VerifiedPaymentCelebration() {
	val progress = remember { Animatable(if (ValueAnimator.areAnimatorsEnabled()) 0f else 1f) }
	val color = MaterialTheme.colorScheme.primary
	LaunchedEffect(Unit) { if (progress.value < 1f) progress.animateTo(1f, tween(1800)) }
	Box(Modifier.fillMaxWidth().height(160.dp).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
		if (progress.value < 1f) Canvas(Modifier.fillMaxSize()) {
			val p = progress.value
			repeat(44) { index ->
				val angle = index * 2.399963
				val reach = size.minDimension * (.26f + index % 5 * .045f)
				val distance = reach * (1 - (1 - p) * (1 - p) * (1 - p))
				drawCircle(color.copy(alpha = (1 - p) * .95f), (2 + index % 3).dp.toPx() * (1 - p * .6f),
					Offset(size.width / 2 + cos(angle).toFloat() * distance,
						size.height / 2 + sin(angle).toFloat() * distance + 28.dp.toPx() * p * p))
			}
		}
		Icon(Icons.Default.CheckCircle, null, Modifier.size(64.dp), tint = color)
	}
}
