package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.dp

/** Reflow the same composition so resizing does not discard drafts or focus. */
@Composable
internal fun WalletColumns(primary: @Composable () -> Unit, secondary: @Composable () -> Unit) {
	WalletGrid {
		Column(verticalArrangement = Arrangement.spacedBy(20.dp)) { primary() }
		Column(verticalArrangement = Arrangement.spacedBy(20.dp)) { secondary() }
	}
}

@Composable
internal fun WalletGrid(content: @Composable () -> Unit) {
	val fontScale = LocalDensity.current.fontScale
	val fold = LocalWalletFold.current
	var windowX by remember { mutableFloatStateOf(0f) }
	Layout(content = content, modifier = Modifier.fillMaxWidth().onGloballyPositioned { windowX = it.positionInWindow().x }) { children, constraints ->
		val gap = 20.dp.roundToPx()
		val hingeLeft = fold?.takeIf { it.vertical }?.let { it.left - windowX.toInt() - gap / 2 }
		val hingeRight = fold?.takeIf { it.vertical }?.let { it.right - windowX.toInt() + gap / 2 }
		val split = hingeLeft != null && hingeRight != null && hingeLeft >= 280.dp.roundToPx() &&
			constraints.maxWidth - hingeRight >= 280.dp.roundToPx()
		val columns = if ((split || constraints.maxWidth >= 700.dp.roundToPx()) && fontScale <= 1.3f) 2 else 1
		val width = (constraints.maxWidth - gap * (columns - 1)) / columns
		val widths = if (columns == 2 && split) listOf(hingeLeft!!, constraints.maxWidth - hingeRight!!) else List(columns) { width }
		val cells = children.mapIndexed { index, child ->
			val w = widths[index % columns]
			child.measure(constraints.copy(minWidth = w, maxWidth = w, minHeight = 0))
		}
		val rows = cells.chunked(columns)
		val height = rows.sumOf { row -> row.maxOf { it.height } } + gap * (rows.size - 1).coerceAtLeast(0)
		layout(constraints.maxWidth, constraints.constrainHeight(height)) {
			var y = 0
			for (row in rows) {
				row.forEachIndexed { index, cell ->
					// Fold bounds use physical window coordinates, including in RTL layouts.
					if (split && columns == 2) cell.place(if (index == 0) 0 else hingeRight!!, y)
					else cell.placeRelative(index * (width + gap), y)
				}
				y += row.maxOf { it.height } + gap
			}
		}
	}
}
