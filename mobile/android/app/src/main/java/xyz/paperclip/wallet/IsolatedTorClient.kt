package xyz.paperclip.wallet

import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.SocketAddress
import java.net.URI
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.net.SocketFactory
import okhttp3.Dns
import okhttp3.OkHttpClient

/** Each client uses a fresh SOCKS authentication identity for Tor circuit isolation. */
internal object IsolatedTorClient {
	fun create(route: String?): OkHttpClient {
		val builder =
			OkHttpClient.Builder()
				.proxy(Proxy.NO_PROXY)
				.followRedirects(false)
				.followSslRedirects(false)
				.retryOnConnectionFailure(false)
				.connectTimeout(30, TimeUnit.SECONDS)
				.readTimeout(30, TimeUnit.SECONDS)
				.pingInterval(30, TimeUnit.SECONDS)
		if (route != null) {
			val proxy = URI(route)
			require(proxy.scheme == "socks5h" && proxy.host != null && proxy.port in 1..65535)
			val address = InetSocketAddress(proxy.host, proxy.port)
			val user = UUID.randomUUID().toString().toByteArray(Charsets.US_ASCII)
			val password = UUID.randomUUID().toString().toByteArray(Charsets.US_ASCII)
			// Preserve the hostname without resolving it. RoutingSocket sends that name to Tor.
			builder.dns(
				object : Dns {
					override fun lookup(hostname: String): List<InetAddress> =
						listOf(InetAddress.getByAddress(hostname, byteArrayOf(0, 0, 0, 1)))
				},
			)
			builder.socketFactory(
				object : SocketFactory() {
					override fun createSocket(): Socket = RoutingSocket(address, user, password)

					override fun createSocket(host: String, port: Int): Socket =
						createSocket().apply {
							connect(InetSocketAddress.createUnresolved(host, port), 30_000)
						}

					override fun createSocket(
						host: String,
						port: Int,
						local: InetAddress,
						localPort: Int,
					): Socket =
						createSocket().apply {
							bind(InetSocketAddress(local, localPort))
							connect(InetSocketAddress.createUnresolved(host, port), 30_000)
						}

					override fun createSocket(host: InetAddress, port: Int): Socket =
						createSocket(host.hostName, port)

					override fun createSocket(
						host: InetAddress,
						port: Int,
						local: InetAddress,
						localPort: Int,
					): Socket = createSocket(host.hostName, port, local, localPort)
				},
			)
		}
		return builder.build()
	}

	private class RoutingSocket(
		val proxy: InetSocketAddress,
		val user: ByteArray,
		val password: ByteArray,
	) : Socket() {
		override fun connect(endpoint: SocketAddress) = connect(endpoint, 30_000)

		override fun connect(endpoint: SocketAddress, timeout: Int) {
			require(endpoint is InetSocketAddress)
			val host = endpoint.hostString.toByteArray(Charsets.US_ASCII)
			require(host.size in 1..255 && endpoint.port in 1..65535)
			try {
				super.connect(proxy, timeout.takeIf { it > 0 } ?: 30_000)
				soTimeout = 30_000
				val input = getInputStream()
				val output = getOutputStream()
				output.write(byteArrayOf(5, 1, 2))
				output.flush()
				require(input.byte() == 5 && input.byte() == 2) {
					"Tor did not accept isolated SOCKS authentication"
				}
				output.write(
					byteArrayOf(1, user.size.toByte()) +
						user +
						byteArrayOf(password.size.toByte()) +
						password,
				)
				output.flush()
				require(input.byte() == 1 && input.byte() == 0) {
					"Tor SOCKS authentication failed"
				}
				output.write(
					byteArrayOf(5, 1, 0, 3, host.size.toByte()) +
						host +
						byteArrayOf((endpoint.port shr 8).toByte(), endpoint.port.toByte()),
				)
				output.flush()
				require(input.byte() == 5 && input.byte() == 0 && input.byte() == 0) {
					"Tor could not connect to the relay"
				}
				val length =
					when (input.byte()) {
						1 -> 4
						3 -> input.byte()
						4 -> 16
						else -> error("Invalid Tor SOCKS reply")
					}
				repeat(length + 2) { input.byte() }
			} catch (failure: Exception) {
				close()
				throw java.io.IOException("Isolated Tor connection failed", failure)
			}
		}

		private fun InputStream.byte(): Int =
			read().also { require(it >= 0) { "Tor closed the SOCKS connection" } }
	}
}
