package xyz.paperclip.wallet

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.unit.dp

/** Static, cached edge light: no content blur, layout padding or continuous animation. */
@Composable
internal fun Modifier.walletEdgeGlow(
	color: Color = MaterialTheme.colorScheme.primary,
	radius: Dp = 26.dp,
	enabled: Boolean = true,
): Modifier {
	if (!enabled) return this
	val strength = if (MaterialTheme.colorScheme.surface.luminance() > .5f) .55f else 1f
	return drawWithCache {
		val glow = Brush.linearGradient(listOf(color.copy(alpha = .65f), color.copy(alpha = .20f), Color.Transparent))
		val corner = CornerRadius(radius.toPx())
		val bands = listOf(14.dp.toPx() to .035f, 9.dp.toPx() to .045f, 4.dp.toPx() to .075f)
		onDrawBehind {
			// Opaque card content covers the inner half; the outer bands fade softly.
			bands.forEach { (width, alpha) ->
				drawRoundRect(glow, cornerRadius = corner, style = Stroke(width), alpha = alpha * strength)
			}
		}
	}
}

/** Opaque surfaces preserve contrast while adding the depth used by the iOS cards. */
@Composable
internal fun walletSurfaceBrush(): Brush {
	val colors = MaterialTheme.colorScheme
	return Brush.linearGradient(listOf(lerp(colors.surface, colors.primary, .045f), colors.surface))
}

@Composable
internal fun walletSurfaceBorder(): BorderStroke {
	val colors = MaterialTheme.colorScheme
	return BorderStroke(1.dp, Brush.linearGradient(listOf(colors.primary.copy(alpha = .25f),
		colors.onSurface.copy(alpha = .09f), colors.onSurface.copy(alpha = .04f))))
}

@Composable
internal fun WalletSurface(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
	Card(modifier.fillMaxWidth().walletEdgeGlow(), shape = RoundedCornerShape(26.dp), border = walletSurfaceBorder(),
		colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
		elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)) {
		Column(Modifier.fillMaxWidth().background(walletSurfaceBrush()), content = content)
	}
}

/** Native button semantics/ripple and system motion scale, with a short spring press. */
@Composable
internal fun WalletPrimaryButton(
	onClick: () -> Unit,
	modifier: Modifier = Modifier,
	enabled: Boolean = true,
	content: @Composable RowScope.() -> Unit,
) {
	val colors = MaterialTheme.colorScheme
	val interaction = remember { MutableInteractionSource() }
	val pressed by interaction.collectIsPressedAsState()
	val scale by animateFloatAsState(if (pressed && enabled) .97f else 1f,
		spring(dampingRatio = .75f, stiffness = 700f), label = "primary-press")
	val shape = RoundedCornerShape(50)
	// Deeper orange keeps white labels readable in both appearances.
	val brush = Brush.verticalGradient(if (enabled) listOf(lerp(colors.primary, Color.Black, .20f), lerp(colors.primary, Color.Black, .28f))
		else listOf(colors.onSurface.copy(alpha = .12f), colors.onSurface.copy(alpha = .12f)))
	Button(onClick = onClick, enabled = enabled, interactionSource = interaction, shape = shape,
		modifier = modifier.heightIn(min = 48.dp).graphicsLayer { scaleX = scale; scaleY = scale }
			.shadow(if (enabled) 5.dp else 0.dp, shape, ambientColor = colors.primary.copy(alpha = .12f), spotColor = colors.primary.copy(alpha = .18f))
			.background(brush, shape),
		colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = Color.White,
			disabledContainerColor = Color.Transparent, disabledContentColor = colors.onSurface.copy(alpha = .38f)),
		contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp), content = content)
}
