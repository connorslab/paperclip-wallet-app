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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.torproject.jni.TorService

/** One bound Tor service per process. Failure never selects a direct route. */
internal object EmbeddedTor {
    private val mutex = Mutex()
    @Volatile private var service: TorService? = null
    private var bound = false
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            service = (binder as TorService.LocalBinder).service
        }
        override fun onServiceDisconnected(name: ComponentName) { service = null }
    }
    suspend fun proxy(context: Context): String = mutex.withLock {
        try { withTimeout(180_000) {
            if (!bound) withContext(Dispatchers.Main) {
                val app = context.applicationContext
                TorService.getTorrc(app).apply {
                    parentFile?.mkdirs()
                    writeText("SocksPort 127.0.0.1:auto\nHTTPTunnelPort 0\nClientOnly 1\nSafeSocks 1\nAvoidDiskWrites 1\n")
                }
                check(app.bindService(Intent(app, TorService::class.java), connection, Context.BIND_AUTO_CREATE)) {
                    "Could not start Tor. No direct connection was attempted."
                }
                bound = true
            }
            withContext(Dispatchers.IO) {
                var endpoint: String? = null
                while (endpoint == null) {
                    val tor = service
                    if (tor?.getInfo("status/circuit-established") == "1") {
                        val port = tor.socksPort
                        if (port in 1..65535) endpoint = "socks5h://127.0.0.1:$port"
                    }
                    if (endpoint == null) delay(500)
                }
                checkNotNull(endpoint)
            }
        } } catch (failure: Exception) {
            withContext(NonCancellable + Dispatchers.Main) {
                if (bound) context.applicationContext.unbindService(connection)
                bound = false
                service = null
            }
            if (failure is TimeoutCancellationException) throw IllegalStateException(
                "Tor could not connect. Check your internet connection and automatic date/time, then try again. No direct connection was attempted.", failure)
            throw failure
        }
    }
}
