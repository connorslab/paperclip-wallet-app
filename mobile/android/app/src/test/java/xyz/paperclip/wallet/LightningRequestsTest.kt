package xyz.paperclip.wallet

import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test

class LightningRequestsTest {
	@Test
	fun authenticatedInfoAndStatusUsePinnedTlsWithoutFollowingRedirects() =
		runBlocking<Unit> {
			val certificate = HeldCertificate.Builder().commonName("fixture").build()
			val server = MockWebServer()
			server.useHttps(
				HandshakeCertificates.Builder()
					.heldCertificate(certificate)
					.build()
					.sslSocketFactory(),
				false,
			)
			server.start()
			try {
				val pin =
					MessageDigest.getInstance("SHA-256")
						.digest(certificate.certificate.encoded)
						.joinToString("") { "%02x".format(it) }
				val connection =
					NodeConnection(
						endpoint = server.url("/").toString(),
						credential = "00",
						pin = pin,
						proxy = "",
					)
				val node = LightningNode(connection, LightningNode.transport(connection, ""))
				server.enqueue(
					MockResponse().setBody("{\"identity_pubkey\":\"02${"11".repeat(32)}\"}"),
				)
				assertEquals(66, node.info().getString("identity_pubkey").length)
				val info = server.takeRequest()
				assertEquals("/v1/getinfo", info.path)
				assertEquals("00", info.getHeader("Grpc-Metadata-macaroon"))
				val hash = "22".repeat(32)
				server.enqueue(
					MockResponse()
						.setBody(
							"{\"result\":{\"payment_hash\":\"$hash\",\"status\":\"SUCCEEDED\"}}\n",
						),
				)
				assertEquals("succeeded", NodePaymentStatus.decode(node.track(hash), hash))
				assertTrue(server.takeRequest().path!!.startsWith("/v2/router/track/"))
				server.enqueue(
					MockResponse().setResponseCode(302).addHeader("Location", server.url("/leak")),
				)
				try {
					node.info()
					fail("Redirect must be rejected")
				} catch (_: IllegalArgumentException) {}
				assertEquals(3, server.requestCount)
			} finally {
				server.shutdown()
			}
		}
}
