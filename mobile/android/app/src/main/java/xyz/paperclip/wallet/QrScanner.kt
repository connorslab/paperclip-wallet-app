package xyz.paperclip.wallet

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.SecureFlagPolicy
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.journeyapps.barcodescanner.BarcodeCallback
import com.journeyapps.barcodescanner.BarcodeResult
import com.journeyapps.barcodescanner.DecoratedBarcodeView

@Composable
internal fun QrScanner(onClose: () -> Unit, onFrame: (String) -> Boolean) {
	val context = LocalContext.current
	val owner = LocalLifecycleOwner.current
	var permitted by remember {
		mutableStateOf(
			ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
				PackageManager.PERMISSION_GRANTED,
		)
	}
	val permission =
		rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
			permitted = it
		}
	var error by remember { mutableStateOf("") }
	val callback by rememberUpdatedState(onFrame)
	val scanner = remember { DecoratedBarcodeView(context) }
	LaunchedEffect(Unit) { if (!permitted) permission.launch(Manifest.permission.CAMERA) }
	Dialog(
		onDismissRequest = onClose,
		properties =
			DialogProperties(
				usePlatformDefaultWidth = false,
				securePolicy = SecureFlagPolicy.SecureOn,
			),
	) {
		Surface(Modifier.fillMaxSize()) {
			Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
				Text("Scan QR", style = MaterialTheme.typography.titleLarge)
				Text(
					"Keep animated frames visible until the request is complete. Scanning never sends a payment.",
				)
				if (permitted)
					AndroidView(
						factory = { scanner },
						modifier = Modifier.weight(1f).fillMaxWidth(),
					)
				else
					Button(onClick = { permission.launch(Manifest.permission.CAMERA) }) {
						Text("Allow camera")
					}
				if (error.isNotEmpty()) Text(error)
				TextButton(onClick = onClose) { Text("Cancel") }
			}
		}
	}
	DisposableEffect(permitted, owner) {
		scanner.decodeContinuous(
			object : BarcodeCallback {
				override fun barcodeResult(result: BarcodeResult) {
					try {
						if (callback(result.text)) {
							scanner.pause()
							onClose()
						}
					} catch (_: Exception) {
						error =
							"Could not read this QR. Show only the expected request or cancel and restart."
					}
				}
			},
		)
		val observer = LifecycleEventObserver { _, event ->
			if (event == Lifecycle.Event.ON_RESUME && permitted) scanner.resume()
			if (event == Lifecycle.Event.ON_PAUSE) scanner.pause()
		}
		owner.lifecycle.addObserver(observer)
		if (permitted && owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
			scanner.resume()
		onDispose {
			scanner.pause()
			owner.lifecycle.removeObserver(observer)
		}
	}
}
