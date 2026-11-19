package xyz.paperclip.wallet

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

// Matches the lid, rounded glass and jam fill of the Jars illustrations.
internal val JarNavigationIcon: ImageVector = ImageVector.Builder(
	name = "Jar", defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f,
).apply {
	addPath(addPathNodes("M7 2H17Q18 2 18 3V4H6V3Q6 2 7 2Z"), fill = SolidColor(Color.Black))
	addPath(addPathNodes("M7 6H17V7.2C17 8.2 20 8.8 20 11V18C20 20.2 18.2 22 16 22H8C5.8 22 4 20.2 4 18V11C4 8.8 7 8.2 7 7.2Z"), fill = null, stroke = SolidColor(Color.Black), strokeLineWidth = 1.75f, strokeLineJoin = StrokeJoin.Round)
	addPath(addPathNodes("M7 14H17V18Q17 19 16 19H8Q7 19 7 18Z"), fill = SolidColor(Color.Black))
}.build()
