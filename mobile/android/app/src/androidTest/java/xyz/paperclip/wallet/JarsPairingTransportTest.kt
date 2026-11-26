package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import java.net.InetAddress
import kotlinx.coroutines.runBlocking
import okhttp3.Dns
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Read-only probe using a synthetic grant. Only run against a designated test endpoint. */
class JarsPairingTransportTest {
	private fun pairingText(changes: Map<String, Any> = emptyMap()): String {
		val value = JSONObject().put("kind", "paperclip-jars-v1").put("scope", "jars_manage_v1").put("endpoint", "https://host.example.invalid")
			.put("wallet", "fixture.jmdat").put("token", "pj1_" + "a".repeat(64)).put("expires", 4_000_000_000L).put("certificate_sha256", "")
		changes.forEach { (key, value_) -> value.put(key, value_) }
		return "paperclip-jars:" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(value.toString().toByteArray())
	}
    @Test fun livePairingTLSWithSyntheticGrant() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val origin = args.getString("pairingOrigin")
        val pins = args.getString("pairingPins")
        org.junit.Assume.assumeTrue(!origin.isNullOrBlank() && !pins.isNullOrBlank())
        suspend fun reachesHost(fingerprints: String): Boolean {
            val pair = JoinBlaketPairing.parse(pairingText(mapOf("endpoint" to origin!!, "certificate_sha256" to fingerprints)))
            val connection = pair.connection
            val base = NodeHTTPTransport.create(connection.endpoint, connection.pin, "")
            // Some emulator networks cannot resolve LAN mDNS. Preserve the real HTTPS authority.
            val address = args.getString("pairingTestAddress")
            val transport = if (address == null) base else base.newBuilder().dns(object : Dns {
                override fun lookup(hostname: String): List<InetAddress> {
                    require(hostname == java.net.URI(origin).host)
                    return listOf(InetAddress.getByName(address))
                }
            }).build()
            try {
                val client = JoinBlaketClient(connection, transport, pair)
                val failure = runCatching { client.status(pair.authorization()) }.exceptionOrNull()
                if (failure is IllegalArgumentException && failure.message.orEmpty().startsWith("Check Jars on your Paperclip host")) return true
                if (failure != null && generateSequence(failure) { it.cause }.any { it is NodePinMismatch }) return false
                throw AssertionError("Expected HTTP 401 or a pin rejection", failure)
            } finally {
                transport.connectionPool.evictAll()
                transport.dispatcher.executorService.shutdown()
            }
        }
        assertTrue(reachesHost(pins!!))
        assertFalse(reachesHost("0".repeat(64)))
        if (',' in pins) assertEquals(1, pins.split(',').count { reachesHost(it) })
    }
}
