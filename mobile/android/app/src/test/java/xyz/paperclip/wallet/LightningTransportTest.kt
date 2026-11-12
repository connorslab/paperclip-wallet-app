package xyz.paperclip.wallet

import java.io.IOException
import java.net.Proxy
import java.security.MessageDigest
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test

class LightningTransportTest {
	@Test
	fun exactCertificatePinAcceptsOnlyTheTrustedLeaf() {
		val cert =
			HeldCertificate.Builder()
				.commonName("test-node")
				.addSubjectAlternativeName("localhost")
				.build()
		val tls = HandshakeCertificates.Builder().heldCertificate(cert).build()
		val server = MockWebServer()
		server.useHttps(tls.sslSocketFactory(), false)
		server.start()
		try {
			val pin =
				MessageDigest.getInstance("SHA-256").digest(cert.certificate.encoded).joinToString(
					"",
				) {
					"%02x".format(it)
				}
			val c =
				NodeConnection(
					endpoint = server.url("/").toString(),
					credential = "00",
					pin = pin,
					proxy = "",
				)
			server.enqueue(MockResponse().setBody("{}"))
			LightningNode.transport(c, "")
				.newCall(Request.Builder().url(server.url("/v1/getinfo")).build())
				.execute()
				.use { assertEquals(200, it.code) }
			val bad = LightningNode.transport(c.copy(pin = "00".repeat(32)), "")
			assertThrows(IOException::class.java) {
				bad.newCall(Request.Builder().url(server.url("/v1/getinfo")).build()).execute()
			}
			assertEquals(1, server.requestCount)
		} finally {
			server.shutdown()
		}
	}

	@Test
	fun configuredTorNeverBecomesDirectAndRequestsAreNotReplayed() {
		val c = NodeConnection(endpoint = "https://example.onion:8180", credential = "00")
		assertThrows(IllegalArgumentException::class.java) { LightningNode.transport(c, "") }
		val client = LightningNode.transport(c, "socks5h://127.0.0.1:1")
		assertEquals(Proxy.Type.SOCKS, client.proxy!!.type())
		assertFalse(client.retryOnConnectionFailure)
		assertFalse(client.followRedirects)
	}
}
