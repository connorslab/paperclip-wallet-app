package xyz.paperclip.wallet

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay

@Composable
internal fun SeedGenerationDialog(model: WalletModel, done: () -> Unit) {
	val context = LocalContext.current
	val capture = remember { SensorEntropyCapture(context.applicationContext) }
	val health by capture.measurements.collectAsState()
	val lifecycle = LocalLifecycleOwner.current
	var method by remember { mutableStateOf("System") }
	var words by remember { mutableIntStateOf(24) }
	var sides by remember { mutableIntStateOf(6) }
	var rolls by remember { mutableStateOf(listOf<Int>()) }
	var fair by remember { mutableStateOf(false) }
	var camera by remember { mutableStateOf(true) }
	var audio by remember { mutableStateOf(true) }
	var motion by remember { mutableStateOf(true) }
	var collecting by remember { mutableStateOf(false) }
	var digest by remember { mutableStateOf<ByteArray?>(null) }
	var error by remember { mutableStateOf("") }
	fun discard() {
		capture.clear()
		digest?.fill(0)
		digest = null
		collecting = false
	}
	val permissions =
		rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
			if (
				lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) &&
					method == "Sensors"
			) {
				capture.start(camera, audio, motion)
				collecting = true
			}
		}
	DisposableEffect(capture, lifecycle) {
		val observer = LifecycleEventObserver { _, event ->
			if (event == Lifecycle.Event.ON_STOP) discard()
		}
		lifecycle.lifecycle.addObserver(observer)
		onDispose {
			lifecycle.lifecycle.removeObserver(observer)
			discard()
		}
	}
	LaunchedEffect(collecting) {
		if (collecting) {
			delay(30000)
			digest = capture.finish()
			collecting = false
		}
	}
	Dialog(onDismissRequest = done) {
		Surface(shape = MaterialTheme.shapes.large) {
			Column(
				Modifier.padding(20.dp).verticalScroll(rememberScrollState()),
				verticalArrangement = Arrangement.spacedBy(12.dp),
			) {
				Text("Generate recovery words", style = MaterialTheme.typography.titleLarge)
				Row {
					listOf(12, 24).forEach { n ->
						FilterChip(words == n, { words = n }, label = { Text("$n words") })
					}
				}
				Row {
					listOf("System", "Dice", "Sensors").forEach { source ->
						FilterChip(
							method == source,
							{
								method = source
								discard()
								rolls = emptyList()
								fair = false
							},
							label = { Text(source) },
						)
					}
				}
				when (method) {
					"System" ->
						Text(
							"Generate ${SeedEntropy.byteCount(words)*8} bits using Android’s secure system random source.",
						)
					"Dice" -> {
						Row {
							listOf(6, 12, 20).forEach { n ->
								FilterChip(
									sides == n,
									{
										sides = n
										rolls = emptyList()
										fair = false
									},
									label = { Text("D$n") },
								)
							}
						}
						Text(
							"${rolls.size} / ${SeedEntropy.requiredRolls(words,sides)} required rolls",
						)
						for (row in (1..sides).chunked(4)) Row(
							horizontalArrangement = Arrangement.spacedBy(6.dp),
						) {
							row.forEach { face ->
								OutlinedButton(
									onClick = { rolls = rolls + face },
									enabled = rolls.size < 1000,
									modifier = Modifier.weight(1f),
									contentPadding = PaddingValues(4.dp),
								) {
									Text(face.toString())
								}
							}
						}
						TextButton(
							onClick = { rolls = rolls.dropLast(1) },
							enabled = rolls.isNotEmpty(),
						) {
							Text("Undo last roll")
						}
						Row {
							Checkbox(fair, { fair = it })
							Text(
								"I used fair physical dice and recorded independent rolls accurately.",
							)
						}
						Text(
							"Dice-only mode adds no system randomness. SHA-256 processes every recorded roll. Biased or predictable rolls cannot be made random by hashing.",
							style = MaterialTheme.typography.bodySmall,
						)
					}
					"Sensors" -> {
						Row {
							Checkbox(
								camera,
								{ camera = it },
								enabled = !collecting && digest == null,
							)
							Text("Camera")
						}
						Row {
							Checkbox(audio, { audio = it }, enabled = !collecting && digest == null)
							Text("Microphone")
						}
						Row {
							Checkbox(
								motion,
								{ motion = it },
								enabled = !collecting && digest == null,
							)
							Text("Gyroscope")
						}
						Text(
							"Samples stay in memory and are never saved or uploaded. They supplement secure system randomness; no extra security bits are claimed.",
						)
						if (collecting)
							Button(
								onClick = {
									digest = capture.finish()
									collecting = false
								},
							) {
								Text("Finish collecting")
							}
						else if (digest != null)
							TextButton(onClick = { discard() }) {
								Text("Discard and collect again")
							}
						else
							Button(
								onClick = {
									val requested = mutableListOf<String>()
									if (camera) requested += Manifest.permission.CAMERA
									if (audio) requested += Manifest.permission.RECORD_AUDIO
									if (requested.isEmpty()) {
										capture.start(false, false, motion)
										collecting = true
									} else permissions.launch(requested.toTypedArray())
								},
								enabled = camera || audio || motion,
							) {
								Text("Collect up to 30 seconds")
							}
						for ((i, value) in health.withIndex()) Text(
							"${listOf("Camera","Audio","Motion")[i]}: $value",
							style = MaterialTheme.typography.bodySmall,
						)
						Text(
							"No samples may mean permission was denied or the sensor is unavailable. Variation is a diagnostic, not a validated entropy estimate.",
							style = MaterialTheme.typography.bodySmall,
						)
					}
				}
				if (error.isNotEmpty()) Text(error, color = MaterialTheme.colorScheme.error)
				val ready =
					when (method) {
						"Dice" -> fair && rolls.size >= SeedEntropy.requiredRolls(words, sides)
						"Sensors" -> digest != null && !collecting
						else -> true
					}
				Button(
					onClick = {
						runCatching {
							val entropy =
								when (method) {
									"Dice" -> SeedEntropy.dice(rolls, sides, words)
									"Sensors" -> {
										val system = SeedEntropy.system(words)
										try {
											SeedEntropy.mix(system, checkNotNull(digest), words)
										} finally {
											system.fill(0)
										}
									}
									else -> SeedEntropy.system(words)
								}
							model.generateFromEntropy(entropy)
							done()
						}
							.onFailure { error = it.message ?: "Could not generate recovery words" }
					},
					enabled = ready,
				) {
					Text("Generate $words words")
				}
				TextButton(onClick = done) { Text("Cancel") }
			}
		}
	}
}
