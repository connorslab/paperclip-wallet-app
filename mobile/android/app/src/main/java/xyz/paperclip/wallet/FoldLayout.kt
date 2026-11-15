package xyz.paperclip.wallet

import androidx.activity.compose.LocalActivity
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import androidx.window.layout.WindowLayoutInfo

internal data class FoldBounds(val left: Int, val top: Int, val right: Int, val bottom: Int, val vertical: Boolean)
internal val LocalWalletFold = staticCompositionLocalOf<FoldBounds?> { null }

/** Single actions and status messages stay entirely on one side of a physical hinge. */
@Composable
internal fun HingeSafeContent(enabled: Boolean = true, limitWidth: Boolean = true, content: @Composable () -> Unit) {
	val fold = LocalWalletFold.current.takeIf { enabled }
	var origin by remember { mutableStateOf(Offset.Zero) }
	Layout(content = { Column(verticalArrangement = Arrangement.spacedBy(20.dp)) { content() } }, modifier = Modifier.onGloballyPositioned { origin = it.positionInWindow() }) { children, constraints ->
		var x = 0
		var width = constraints.maxWidth
		fold?.takeIf { it.vertical }?.let {
			val left = it.left - origin.x.toInt() - 10.dp.roundToPx()
			val right = it.right - origin.x.toInt() + 10.dp.roundToPx()
			if (left > 0 && right < width) {
				if (left >= width - right) width = left else { x = right; width -= right }
			}
		}
		if (enabled && limitWidth) {
			val comfortableWidth = minOf(width, 680.dp.roundToPx())
			x += (width - comfortableWidth) / 2
			width = comfortableWidth
		}
		val cells = children.map { it.measure(constraints.copy(minWidth = 0, maxWidth = width)) }
		layout(constraints.maxWidth, cells.maxOfOrNull { it.height } ?: 0) { cells.forEach { it.place(x, 0) } }
	}
}

@Composable
internal fun FoldInformation(content: @Composable () -> Unit) {
	val activity = LocalActivity.current
	if (activity == null) { content(); return }
	val flow: kotlinx.coroutines.flow.Flow<WindowLayoutInfo?> = remember(activity) { WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity) }
	val info by flow.collectAsStateWithLifecycle(initialValue = null)
	val fold = info?.displayFeatures.orEmpty().filterIsInstance<FoldingFeature>().firstOrNull {
		it.isSeparating || it.occlusionType == FoldingFeature.OcclusionType.FULL
	}?.let { FoldBounds(it.bounds.left, it.bounds.top, it.bounds.right, it.bounds.bottom,
		it.orientation == FoldingFeature.Orientation.VERTICAL) }
	CompositionLocalProvider(LocalWalletFold provides fold) { content() }
}

/** Tabletop uses one unobstructed pane. Book posture can span two usable panes. */
@Composable
internal fun FoldAwareFrame(allowColumns: Boolean, content: @Composable () -> Unit) {
	val fold = LocalWalletFold.current
	val density = LocalDensity.current
	var origin by remember { mutableStateOf(Offset.Zero) }
	Layout(content = content, modifier = Modifier.fillMaxSize().onGloballyPositioned { origin = it.positionInWindow() }) { children, constraints ->
		var x = 0; var y = 0; var width = constraints.maxWidth; var height = constraints.maxHeight
		fold?.let {
			if (it.vertical) {
				val left = (it.left - origin.x.toInt()).coerceIn(0, width)
				val right = (it.right - origin.x.toInt()).coerceIn(0, width)
				val canSplit = allowColumns && density.fontScale <= 1.3f &&
					minOf(left, width - right) >= 340.dp.roundToPx()
				if (left > 0 && right < width && !canSplit) {
					if (left >= width - right) width = left else { x = right; width -= right }
				}
			} else {
				val top = (it.top - origin.y.toInt()).coerceIn(0, height)
				val bottom = (it.bottom - origin.y.toInt()).coerceIn(0, height)
				if (top > 0 && bottom < height) {
					if (top >= height - bottom) height = top else { y = bottom; height -= bottom }
				}
			}
		}
		val placeables = children.map { it.measure(Constraints.fixed(width, height)) }
		layout(constraints.maxWidth, constraints.maxHeight) { placeables.forEach { it.place(x, y) } }
	}
}
