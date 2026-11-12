package xyz.paperclip.wallet

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.torproject.jni.TorService

/** One bound Tor service per process. Failure never selects a direct route. */
internal object EmbeddedTor {
	private val mutex = Mutex()
	private val progress = MutableStateFlow("Tor not started")
	val status = progress.asStateFlow()
	@Volatile private var service: TorService? = null
	private var bound = false
	private val connection =
		object : ServiceConnection {
			override fun onServiceConnected(name: ComponentName, binder: IBinder) {
				service = (binder as TorService.LocalBinder).service
			}

			override fun onServiceDisconnected(name: ComponentName) {
				service = null
			}
		}

	suspend fun proxy(context: Context): String = mutex.withLock {
		var stage = "starting the Tor service"
		progress.value = "Starting Tor…"
		try {
			withTimeout(180_000) {
				if (!bound)
					withContext(Dispatchers.Main) {
						val app = context.applicationContext
						TorService.getTorrc(app).apply {
							parentFile?.mkdirs()
							writeText(
								"SocksPort 127.0.0.1:auto IsolateSOCKSAuth\nHTTPTunnelPort 0\nClientOnly 1\nSafeSocks 1\nAvoidDiskWrites 1\n",
							)
						}
						check(
							app.bindService(
								Intent(app, TorService::class.java),
								connection,
								Context.BIND_AUTO_CREATE,
							),
						) {
							"Could not start Tor. No direct connection was attempted."
						}
						bound = true
					}
				withContext(Dispatchers.IO) {
					var endpoint: String? = null
					while (endpoint == null) {
						val tor = service
						if (tor == null) {
							stage = "waiting for the Tor service"
						} else {
							stage = "waiting for Tor control and bootstrap"
							val phase = runCatching {
								tor.getInfo("status/bootstrap-phase")
							}
								.getOrNull()
							val percent = phase?.let {
								Regex("PROGRESS=([0-9]{1,3})")
									.find(it)
									?.groupValues
									?.get(1)
									?.toIntOrNull()
							}
							progress.value =
								percent?.takeIf { it in 0..100 }?.let { "Connecting to Tor · $it%" }
									?: "Waiting for Tor control…"
						}
						if (
							tor != null &&
								runCatching { tor.getInfo("status/circuit-established") }
									.getOrNull() == "1"
						) {
							stage = "waiting for the Tor SOCKS listener"
							val port = tor.socksPort
							if (port in 1..65535) endpoint = "socks5h://127.0.0.1:$port"
						}
						if (endpoint == null) delay(500)
					}
					progress.value = "Tor connected"
					checkNotNull(endpoint)
				}
			}
		} catch (failure: Exception) {
			withContext(NonCancellable + Dispatchers.Main) {
				if (bound) context.applicationContext.unbindService(connection)
				bound = false
				service = null
			}
			progress.value = "Tor failed while $stage. Retry to start a fresh connection."
			if (failure is TimeoutCancellationException)
				throw IllegalStateException(
					"Tor timed out while $stage. Check your connection and automatic date/time, then retry. No direct connection was attempted.",
					failure,
				)
			throw failure
		}
	}
}
