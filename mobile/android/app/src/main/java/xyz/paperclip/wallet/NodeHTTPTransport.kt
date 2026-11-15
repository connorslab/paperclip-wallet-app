package xyz.paperclip.wallet

import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URI
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import okhttp3.OkHttpClient

/** Used only after validating the endpoint, exact leaf pin and explicit Tor route. */
internal object NodeHTTPTransport {
	fun create(endpoint: String, pin: String, route: String): OkHttpClient {
			val b =
				OkHttpClient.Builder()
					.followRedirects(false)
					.followSslRedirects(false)
					.retryOnConnectionFailure(false)
					.connectTimeout(30, TimeUnit.SECONDS)
					.readTimeout(60, TimeUnit.SECONDS)
					.callTimeout(90, TimeUnit.SECONDS)
					.cache(null)
			b.proxy(
				if (route.isBlank()) Proxy.NO_PROXY
				else
					URI(route).let {
						require(it.scheme == "socks5h" && it.host != null && it.port in 1..65535)
						Proxy(Proxy.Type.SOCKS, InetSocketAddress(it.host, it.port))
					},
			)
			if (pin.isNotBlank()) {
				val pins = pin.lowercase().split(',').map(String::trim).toSet()
				fun matches(cert: X509Certificate) =
					MessageDigest.getInstance("SHA-256").digest(cert.encoded).joinToString("") {
						"%02x".format(it)
					} in pins
				val trust =
					object : X509TrustManager {
						override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

						override fun checkClientTrusted(
							chain: Array<X509Certificate>,
							authType: String,
						) {
							throw CertificateException("Client certificates are unsupported")
						}

						override fun checkServerTrusted(
							chain: Array<X509Certificate>,
							authType: String,
						) {
							if (chain.isEmpty() || !matches(chain[0]))
								throw CertificateException(
									"The node TLS certificate does not match any saved SHA256 fingerprint",
								)
						}
					}
				val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
				b.sslSocketFactory(tls.socketFactory, trust)
				// Exact leaf pin is the user's trust anchor, including self-signed onion
				// certificates.
				b.hostnameVerifier { host, session ->
					host == URI(endpoint).host &&
						runCatching { matches(session.peerCertificates[0] as X509Certificate) }
							.getOrDefault(false)
				}
			}
			return b.build()
	}
}
