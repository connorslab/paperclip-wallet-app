package xyz.paperclip.wallet

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.ImageReader
import android.media.MediaRecorder
import android.os.Handler
import android.os.HandlerThread
import androidx.core.content.ContextCompat
import java.nio.ByteBuffer
import java.security.MessageDigest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal class SensorHealth {
	var packets = 0
		private set

	var repeated = 0
		private set

	var sampled = 0
		private set

	var longestRun = 0
		private set

	private var previous: ByteArray? = null
	private var repeats = 0
	private var last = -1
	private var run = 0
	private val histogram = IntArray(256)
	val distinct
		get() = histogram.count { it > 0 }

	val common
		get() = if (sampled == 0) 0.0 else histogram.max().toDouble() / sampled

	val status
		get() =
			when {
				packets == 0 -> "No samples"
				distinct <= 1 || repeats >= 2 -> "Repetitive input detected"
				packets < 3 || sampled < 256 -> "Insufficient samples for diagnostics"
				else -> "Variation observed · entropy not validated"
			}

	fun observe(bytes: ByteArray) {
		if (bytes.isEmpty()) return
		val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
		if (previous?.contentEquals(digest) == true) {
			repeated++
			repeats++
		} else repeats = 0
		previous?.fill(0)
		previous = digest
		packets++
		fun byte(value: Byte) {
			val n = value.toInt() and 255
			histogram[n]++
			sampled++
			run = if (last == n) run + 1 else 1
			last = n
			longestRun = maxOf(longestRun, run)
		}
		if (bytes.size <= 4096) bytes.forEach(::byte)
		else
			repeat(256) { block ->
				val offset = block * (bytes.size - 16) / 255
				repeat(16) { byte(bytes[offset + it]) }
			}
	}

	fun description() =
		"$status · $packets packets · $sampled sampled bytes · $distinct byte values · ${(common*100).toInt()}% most common · $repeated repeated packets · longest run $longestRun"
}

/** Samples are hashed in memory, never recorded to disk or transmitted. */
internal class SensorEntropyCapture(private val context: Context) {
	private val lock = Any()
	private var active = false
	private var generation = 0L
	private var hasher = MessageDigest.getInstance("SHA-256")
	private var health = Array(3) { SensorHealth() }
	private val mutable = MutableStateFlow(List(3) { "No samples" })
	val measurements = mutable.asStateFlow()
	private var thread: HandlerThread? = null
	private var camera: CameraDevice? = null
	private var reader: ImageReader? = null
	private var session: CameraCaptureSession? = null
	private var audio: AudioRecord? = null
	private var audioThread: Thread? = null
	private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
	private var motion: SensorEventListener? = null

	private fun allowed(permission: String) =
		ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

	private fun add(ticket: Long, source: Int, bytes: ByteArray) {
		try {
			synchronized(lock) {
				if (!active || generation != ticket || bytes.isEmpty()) return
				hasher.update(source.toByte())
				hasher.update(ByteBuffer.allocate(8).putLong(bytes.size.toLong()).array())
				hasher.update(bytes)
				health[source].observe(bytes)
				mutable.value = health.map { it.description() }
			}
		} finally {
			bytes.fill(0)
		}
	}

	@Synchronized
	fun start(useCamera: Boolean, useAudio: Boolean, useMotion: Boolean) {
		clear()
		val ticket =
			synchronized(lock) {
				generation++
				active = true
				hasher.update("Paperclip/sensor-stream/v1".toByteArray())
				generation
			}
		val worker = HandlerThread("paperclip-seed-samples").also { it.start() }
		thread = worker
		val handler = Handler(worker.looper)
		if (useMotion) {
			val listener =
				object : SensorEventListener {
					override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

					override fun onSensorChanged(event: SensorEvent) {
						// No timestamp enters the diagnostics; a clock cannot hide a stuck sensor.
						val bytes = ByteBuffer.allocate(event.values.size * 4)
						event.values.forEach { bytes.putFloat(it) }
						add(ticket, 2, bytes.array())
					}
				}
			motion = listener
			sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE)?.let {
				sensors.registerListener(listener, it, 50000, handler)
			}
		}
		if (useCamera && allowed(Manifest.permission.CAMERA)) startCamera(handler, ticket)
		if (useAudio && allowed(Manifest.permission.RECORD_AUDIO)) startAudio(ticket)
		handler.postDelayed({ finish(ticket) }, 30000)
	}

	@Suppress("MissingPermission", "DEPRECATION")
	private fun startCamera(handler: Handler, ticket: Long) {
		runCatching {
			val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
			val id =
				manager.cameraIdList.firstOrNull {
					manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) ==
						CameraCharacteristics.LENS_FACING_BACK
				} ?: manager.cameraIdList.first()
			val sizes =
				manager
					.getCameraCharacteristics(id)
					.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
					.getOutputSizes(ImageFormat.YUV_420_888)
			val size =
				sizes
					.filter { it.width <= 640 && it.height <= 480 }
					.maxByOrNull { it.width * it.height } ?: sizes.minBy { it.width * it.height }
			val images =
				ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
			reader = images
			var last = 0L
			images.setOnImageAvailableListener(
				{ available ->
					runCatching {
						available.acquireLatestImage()?.use { image ->
							if (System.nanoTime() - last < 200000000) return@use
							last = System.nanoTime()
							val buffer = image.planes.first().buffer
							if (buffer.remaining() <= 1048576)
								add(
									ticket,
									0,
									ByteArray(buffer.remaining()).also { buffer.get(it) },
								)
						}
					}
				},
				handler,
			)
			manager.openCamera(
				id,
				object : CameraDevice.StateCallback() {
					override fun onOpened(device: CameraDevice) {
						synchronized(lock) {
							if (!active || generation != ticket) {
								device.close()
								return
							}
							camera = device
						}
						runCatching {
							device.createCaptureSession(
								listOf(images.surface),
								object : CameraCaptureSession.StateCallback() {
									override fun onConfigured(value: CameraCaptureSession) {
										synchronized(lock) {
											if (!active || generation != ticket) {
												value.close()
												return
											}
											session = value
										}
										runCatching {
											value.setRepeatingRequest(
												device
													.createCaptureRequest(
														CameraDevice.TEMPLATE_PREVIEW,
													)
													.apply { addTarget(images.surface) }
													.build(),
												null,
												handler,
											)
										}
									}

									override fun onConfigureFailed(
										value: CameraCaptureSession,
									) {
										value.close()
									}
								},
								handler,
							)
						}
							.onFailure { device.close() }
					}

					override fun onDisconnected(device: CameraDevice) {
						device.close()
					}

					override fun onError(device: CameraDevice, error: Int) {
						device.close()
					}
				},
				handler,
			)
		}
	}

	@Suppress("MissingPermission")
	private fun startAudio(ticket: Long) {
		runCatching {
			val minimum =
				AudioRecord.getMinBufferSize(
					16000,
					AudioFormat.CHANNEL_IN_MONO,
					AudioFormat.ENCODING_PCM_16BIT,
				)
			require(minimum > 0)
			val capture =
				AudioRecord(
					MediaRecorder.AudioSource.MIC,
					16000,
					AudioFormat.CHANNEL_IN_MONO,
					AudioFormat.ENCODING_PCM_16BIT,
					maxOf(minimum, 4096),
				)
			audio = capture
			require(capture.state == AudioRecord.STATE_INITIALIZED)
			capture.startRecording()
			audioThread =
				Thread {
					val bytes = ByteArray(4096)
					try {
						while (synchronized(lock) { active && generation == ticket }) {
							val count = capture.read(bytes, 0, bytes.size)
							if (count <= 0) break
							add(ticket, 1, bytes.copyOf(count))
						}
					} catch (_: Exception) {} finally {
						bytes.fill(0)
					}
				}
					.also { it.start() }
		}
	}

	@Volatile private var digest: ByteArray? = null

	@Synchronized
	fun finish(ticket: Long? = null): ByteArray? {
		synchronized(lock) {
			if (ticket != null && generation != ticket) return null
			if (active) {
				active = false
				digest = if (health.any { it.packets > 0 }) hasher.digest() else null
			}
		}
		motion?.let(sensors::unregisterListener)
		motion = null
		runCatching { session?.close() }
		session = null
		runCatching { camera?.close() }
		camera = null
		runCatching { reader?.close() }
		reader = null
		runCatching { audio?.stop() }
		runCatching { audio?.release() }
		audio = null
		thread?.quitSafely()
		thread = null
		return digest?.copyOf()
	}

	@Synchronized
	fun clear() {
		finish()
		digest?.fill(0)
		digest = null
		synchronized(lock) {
			generation++
			hasher = MessageDigest.getInstance("SHA-256")
			health = Array(3) { SensorHealth() }
			mutable.value = List(3) { "No samples" }
		}
	}
}
