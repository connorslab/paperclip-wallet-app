package xyz.paperclip.wallet

import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class IsolatedTorClientTest {
	private fun InputStream.bytes(count: Int): ByteArray =
		ByteArray(count).also { bytes ->
			for (i in bytes.indices) {
				val value = read()
				check(value >= 0)
				bytes[i] = value.toByte()
			}
		}

	@Test
	fun distinctClientsAuthenticateSeparatelyAndSendHostnamesToTor() {
		val executor = Executors.newSingleThreadExecutor()
		ServerSocket(0, 2, InetAddress.getLoopbackAddress()).use { proxy ->
			proxy.soTimeout = 5000
			val observed =
				executor.submit<List<Pair<String, String>>> {
					(0..1).map {
						proxy.accept().use { socket ->
							socket.soTimeout = 5000
							val input = socket.getInputStream()
							val output = socket.getOutputStream()
							assertArrayEquals(byteArrayOf(5, 1, 2), input.bytes(3))
							output.write(byteArrayOf(5, 2))
							output.flush()
							assertEquals(1, input.read())
							val user = String(input.bytes(input.read()))
							val password = String(input.bytes(input.read()))
							output.write(byteArrayOf(1, 0))
							output.flush()
							assertArrayEquals(byteArrayOf(5, 1, 0, 3), input.bytes(4))
							val host = String(input.bytes(input.read()))
							assertEquals("unresolvable-test.onion", host)
							assertArrayEquals(byteArrayOf(1, -69), input.bytes(2)) // 443
							output.write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 1))
							output.flush()
							user to password
						}
					}
				}
			try {
				repeat(2) {
					val client = IsolatedTorClient.create("socks5h://127.0.0.1:${proxy.localPort}")
					val unresolved = client.dns.lookup("unresolvable-test.onion").single()
					client.socketFactory.createSocket().use { socket ->
						socket.connect(InetSocketAddress(unresolved, 443), 5000)
					}
				}
				val identities = observed.get(5, TimeUnit.SECONDS)
				assertNotEquals(identities[0].first, identities[1].first)
				assertNotEquals(identities[0].second, identities[1].second)
			} finally {
				executor.shutdownNow()
			}
		}
	}
}
