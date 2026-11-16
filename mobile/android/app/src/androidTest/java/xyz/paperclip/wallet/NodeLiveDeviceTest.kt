package xyz.paperclip.wallet

import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.net.InetAddress
import java.net.URI
import javax.net.ssl.SSLException
import kotlinx.coroutines.runBlocking
import okhttp3.Dns
import okhttp3.OkHttpClient
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Explicit opt-in, read-only device transport check. Never opens a wallet session. */
class NodeLiveDeviceTest {
	@Test fun authenticatedReadsAndPinRecovery() = runBlocking {
		assumeTrue(InstrumentationRegistry.getArguments().getString("liveNodes") == "true")
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		val clients = mutableListOf<OkHttpClient>()
		var stage = "private-input"
		try {
			// Provision this file through run-as on an unfunded QA emulator only.
			// Do not pass credentials in instrumentation arguments or log responses.
			val cases = JSONObject(File(context.cacheDir, "node-live-read.json").readText()).getJSONArray("cases")
			check(cases.length() > 0)
			for (index in 0 until cases.length()) {
				stage = "private-input"
				val item = cases.getJSONObject(index)
				val config = item.getJSONObject("connection")
				val useTor = config.getBoolean("useTor")
				val c = NodeConnection(
					implementation = config.getString("implementation"), endpoint = config.getString("endpoint"),
					credential = config.getString("credential"), pin = config.getString("certificateSHA256"), proxy = if (useTor) "builtin" else "",
				)
				check(c.implementation in setOf("cln", "lnd"))
				val uri = URI(c.endpoint)
				check(uri.scheme == "https")
				check(!uri.host.endsWith(".onion") || useTor)
				check(c.pin.isNotBlank())
				c.validate()
				val expected = item.getString("expectedIdentity")
				check(expected.matches(Regex("[0-9a-fA-F]{66}")))
				fun record(step: String, elapsed: Long? = null) {
					Log.i("PaperclipNodeReadProbe", "case=$index stage=$step passed" + (elapsed?.let { " elapsedMs=$it" } ?: ""))
				}
				stage = if (useTor) "embedded-tor" else "direct-tls"
				var began = android.os.SystemClock.elapsedRealtime()
				val route = if (useTor) EmbeddedTor.proxy(context) else ""
				record(stage, android.os.SystemClock.elapsedRealtime() - began)
				fun node(connection: NodeConnection): LightningNode {
					val base = LightningNode.transport(connection, route)
					// Emulator networks may not resolve host LAN mDNS. A private, explicit
					// address fixture changes DNS only; HTTPS authority/SNI and pins stay intact.
					val address = item.optString("resolvedAddress").takeIf { it.isNotBlank() }
					val client = if (address == null) base else {
						check(!useTor)
						check(address.matches(Regex("[0-9]{1,3}(\\.[0-9]{1,3}){3}")))
						base.newBuilder().dns(object : Dns {
							override fun lookup(hostname: String): List<InetAddress> {
								check(hostname == uri.host)
								return listOf(InetAddress.getByName(address))
							}
						}).build()
					}
					clients.add(client)
					return LightningNode(connection, client)
				}
				val node = node(c)
				repeat(3) {
					stage = "getinfo-${it + 1}"
					began = android.os.SystemClock.elapsedRealtime()
					val info = node.info()
					check(expected.equals(info.getString(if (c.implementation == "lnd") "identity_pubkey" else "id"), ignoreCase = true))
					NodeNetwork.decode(info, c.implementation == "lnd")
					record(stage, android.os.SystemClock.elapsedRealtime() - began)
					stage = "balance-${it + 1}"
					node.balance()
					record(stage)
				}
				stage = "wrong-pin"
				var rejected = false
				try { node(c.copy(pin = "0".repeat(64))).info() }
				catch (_: SSLException) { rejected = true }
				check(rejected)
				record(stage)
				stage = "after-pin-failure"
				node.info()
				record(stage)
			}
		} catch (failure: Throwable) {
			// No exception cause/message: transport/parser errors can contain private data.
			throw AssertionError("Live node check failed at $stage (${failure.javaClass.simpleName})")
		} finally {
			clients.forEach { it.dispatcher.cancelAll(); it.connectionPool.evictAll(); it.dispatcher.executorService.shutdown() }
		}
	}
}
