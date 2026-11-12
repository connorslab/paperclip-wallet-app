package xyz.paperclip.wallet

import java.io.ByteArrayInputStream
import java.net.URI
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.java_websocket.WebSocketImpl
import org.java_websocket.client.WebSocketClient
import org.java_websocket.enums.Role
import org.java_websocket.exceptions.LimitExceededException
import org.java_websocket.framing.BinaryFrame
import org.java_websocket.framing.ContinuousFrame
import org.java_websocket.handshake.ServerHandshake
import org.junit.Assert.*
import org.junit.Test

class BoundedRelayTest {
	@Test
	fun oversizedFrameIsRejectedBeforeReadingPayload() {
		val draft = RelayDraft().apply { setParseMode(Role.CLIENT) }
		val header =
			ByteBuffer.allocate(10)
				.put(0x81.toByte())
				.put(127.toByte())
				.putLong(RelayDraft.MAX_MESSAGE.toLong() + 1)
				.apply { flip() }
		assertThrows(LimitExceededException::class.java) { draft.translateFrame(header) }
	}

	@Test
	fun emptyContinuationFloodIsBounded() {
		val draft = RelayDraft()
		val client =
			object : WebSocketClient(URI("wss://example.invalid"), draft) {
				override fun onOpen(handshake: ServerHandshake) {}

				override fun onMessage(text: String) {}

				override fun onClose(code: Int, reason: String, remote: Boolean) {}

				override fun onError(error: Exception) {}
			}
		val connection = client.connection as WebSocketImpl
		draft.processFrame(connection, BinaryFrame().apply { isFin = false })
		repeat(1023) { draft.processFrame(connection, ContinuousFrame().apply { isFin = false }) }
		assertThrows(LimitExceededException::class.java) {
			draft.processFrame(connection, ContinuousFrame().apply { isFin = false })
		}
	}

	@Test
	fun httpUpgradeIsBoundedWithoutLimitingSubsequentFrames() {
		val huge = RelayHandshakeInput(ByteArrayInputStream(ByteArray(65537) { 65 }))
		assertThrows(IllegalStateException::class.java) { huge.readBytes() }
		val valid = "HTTP/1.1 101 Switching Protocols\r\n\r\n".toByteArray() + ByteArray(100000)
		assertEquals(valid.size, RelayHandshakeInput(ByteArrayInputStream(valid)).readBytes().size)
	}

	@Test
	fun relayNegotiatesTlsAndRejectsWrongHostname() {
		for (validHost in listOf(true, false)) {
			val cert =
				HeldCertificate.Builder()
					.addSubjectAlternativeName(if (validHost) "localhost" else "wrong.invalid")
					.build()
			val serverTls = HandshakeCertificates.Builder().heldCertificate(cert).build()
			val trusted =
				HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
			val server = MockWebServer()
			server.useHttps(serverTls.sslSocketFactory(), false)
			server.enqueue(
				MockResponse()
					.withWebSocketUpgrade(
						object : WebSocketListener() {
							override fun onOpen(webSocket: WebSocket, response: Response) {
								webSocket.send("hello")
							}
						},
					),
			)
			server.start()
			val opened = CountDownLatch(1)
			val message = CountDownLatch(1)
			val failure = CountDownLatch(1)
			val relay =
				BoundedRelay(
					URI("wss://localhost:${server.port}/"),
					null,
					{ opened.countDown() },
					{ _, text -> if (text == "hello") message.countDown() },
					{ failure.countDown() },
					trusted.sslSocketFactory(),
				)
			try {
				relay.connect()
				if (validHost) {
					assertTrue(opened.await(5, TimeUnit.SECONDS))
					assertTrue(message.await(5, TimeUnit.SECONDS))
				} else {
					assertTrue(failure.await(5, TimeUnit.SECONDS))
					assertEquals(1L, opened.count)
				}
			} finally {
				relay.cancel()
				server.shutdown()
			}
		}
	}
}
