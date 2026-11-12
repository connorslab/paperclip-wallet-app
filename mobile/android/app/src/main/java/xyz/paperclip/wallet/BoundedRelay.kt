package xyz.paperclip.wallet

import java.io.FilterInputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import org.java_websocket.WebSocketImpl
import org.java_websocket.client.WebSocketClient
import org.java_websocket.drafts.Draft
import org.java_websocket.drafts.Draft_6455
import org.java_websocket.enums.Opcode
import org.java_websocket.exceptions.LimitExceededException
import org.java_websocket.framing.Framedata
import org.java_websocket.handshake.ServerHandshake

/** Limits fragments as well as bytes; empty fragments cannot accumulate indefinitely. */
internal class RelayDraft : Draft_6455(emptyList(), MAX_MESSAGE) {
	private var fragments = 0
	private var bytes = 0L

	override fun copyInstance(): Draft = RelayDraft()

	override fun processFrame(connection: WebSocketImpl, frame: Framedata) {
		if (frame.opcode in setOf(Opcode.TEXT, Opcode.BINARY, Opcode.CONTINUOUS)) {
			fragments++
			bytes += frame.payloadData.remaining()
			if (fragments > 1024 || bytes > MAX_MESSAGE)
				throw LimitExceededException("Relay message too large")
			if (frame.isFin) {
				fragments = 0
				bytes = 0
			}
		}
		super.processFrame(connection, frame)
	}

	companion object {
		const val MAX_MESSAGE = 524288
	}
}

/** The HTTP upgrade parser must also have a limit, before WebSocket framing begins. */
internal class RelayHandshakeInput(input: InputStream) : FilterInputStream(input) {
	private var count = 0
	private var ending = 0
	private var complete = false

	private fun inspect(value: Int) {
		if (value < 0 || complete) return
		check(++count <= 65536) { "Relay handshake too large" }
		ending = (ending shl 8) or value
		if (ending == 0x0d0a0d0a) complete = true
	}

	override fun read(): Int = super.read().also(::inspect)

	override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
		val read = `in`.read(buffer, offset, length)
		for (i in 0 until read) inspect(buffer[offset + i].toInt() and 255)
		return read
	}
}

/** TLS is negotiated with hostname validation before handing the socket to the relay library. */
internal class BoundedRelay(
	private val address: URI,
	private val route: String?,
	private val opened: (BoundedRelay) -> Unit,
	private val received: (BoundedRelay, String) -> Unit,
	private val failed: () -> Unit,
	private val tlsFactory: SSLSocketFactory = SSLSocketFactory.getDefault() as SSLSocketFactory,
) {
	private val canceled = AtomicBoolean(false)
	@Volatile private var transport: Socket? = null
	private val client =
		object : WebSocketClient(address, RelayDraft(), emptyMap(), 30000) {
			override fun run() {
				try {
					require(address.scheme == "wss")
					val routing = IsolatedTorClient.create(route)
					val plain = routing.socketFactory.createSocket()
					transport = plain
					if (canceled.get()) {
						plain.close()
						return
					}
					val port = if (address.port == -1) 443 else address.port
					plain.connect(
						InetSocketAddress(routing.dns.lookup(address.host).first(), port),
						30000,
					)
					plain.soTimeout = 30000
					val tls = tlsFactory.createSocket(plain, address.host, port, true) as SSLSocket
					transport = tls
					tls.sslParameters =
						tls.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
					tls.startHandshake()
					tls.soTimeout = 60000
					if (canceled.get()) {
						tls.close()
						return
					}
					// setSocket accepts an already connected transport. Its automatic TLS
					// upgrade is deliberately unused; validation above is mandatory.
					@Suppress("DEPRECATION")
					setSocket(
						object : Socket() {
							private val input = RelayHandshakeInput(tls.inputStream)

							override fun getInputStream() = input

							override fun getOutputStream() = tls.outputStream

							override fun isConnected() = tls.isConnected

							override fun isClosed() = tls.isClosed

							override fun setTcpNoDelay(value: Boolean) {
								tls.tcpNoDelay = value
							}

							override fun setReuseAddress(value: Boolean) {
								tls.reuseAddress = value
							}

							override fun setReceiveBufferSize(value: Int) {
								tls.receiveBufferSize = value
							}

							override fun getLocalSocketAddress() = tls.localSocketAddress

							override fun getRemoteSocketAddress() = tls.remoteSocketAddress

							override fun close() = tls.close()
						},
					)
					super.run()
				} catch (_: Exception) {
					transport?.close()
					if (!canceled.get()) failed()
				}
			}

			override fun onOpen(handshake: ServerHandshake) {
				opened(this@BoundedRelay)
			}

			override fun onMessage(message: String) {
				received(this@BoundedRelay, message)
			}

			override fun onMessage(message: ByteBuffer) {
				try {
					val text =
						Charsets.UTF_8.newDecoder()
							.onMalformedInput(CodingErrorAction.REPORT)
							.decode(message)
							.toString()
					received(this@BoundedRelay, text)
				} catch (_: Exception) {
					cancel()
				}
			}

			override fun onClose(code: Int, reason: String, remote: Boolean) {
				if (!canceled.get()) failed()
			}

			override fun onError(error: Exception) {
				if (!canceled.get()) failed()
			}
		}

	init {
		client.connectionLostTimeout = 30
	}

	fun connect() {
		client.connect()
	}

	fun send(text: String): Boolean {
		if (!client.isOpen || canceled.get() || text.toByteArray().size > RelayDraft.MAX_MESSAGE)
			return false
		return runCatching {
				client.send(text)
				true
			}
			.getOrDefault(false)
	}

	fun cancel() {
		canceled.set(true)
		runCatching { transport?.close() }
		client.closeConnection(1000, "")
	}
}
