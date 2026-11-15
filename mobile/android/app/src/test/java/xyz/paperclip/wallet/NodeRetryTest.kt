package xyz.paperclip.wallet

import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLHandshakeException
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NodeRetryTest {
	private fun client(count: AtomicInteger, error: IOException?, status: Int = 200): OkHttpClient =
		OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
			if (count.incrementAndGet() == 1 && error != null) throw error
			Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
				.code(status).message("fixture").body("{}".toResponseBody()).build()
		}.build()

	@Test fun readOnlyCLNPostAndLNDGetRetryOnce() = runBlocking {
		for (implementation in listOf("cln", "lnd")) {
			val count = AtomicInteger()
			val node = LightningNode(NodeConnection(endpoint = "https://node.invalid", credential = "00", implementation = implementation), client(count, IOException("disconnect")))
			node.info()
			assertEquals(2, count.get())
		}
	}

	@Test fun mutationsAuthorizationAndTLSNeverRetry() = runBlocking {
		for (path in listOf("v1/pay", "v2/router/send", "v1/invoice", "v1/invoices", "v2/offers", "v2/offers/fetchinvoice")) {
			val count = AtomicInteger()
			val node = LightningNode(NodeConnection(endpoint = "https://node.invalid", credential = "00"), client(count, IOException("disconnect")))
			try { node.request(path, JSONObject()); fail("Mutation must not be replayed") } catch (_: IOException) {}
			assertEquals(1, count.get())
		}
		for (status in listOf(401, 403)) {
			val count = AtomicInteger()
			val node = LightningNode(NodeConnection(endpoint = "https://node.invalid", credential = "00"), client(count, null, status))
			try { node.info(); fail("Authorization must fail") } catch (_: IllegalStateException) {}
			assertEquals(1, count.get())
		}
		val count = AtomicInteger()
		val node = LightningNode(NodeConnection(endpoint = "https://node.invalid", credential = "00"), client(count, SSLHandshakeException("pin mismatch")))
		try { node.info(); fail("TLS must fail") } catch (_: SSLHandshakeException) {}
		assertEquals(1, count.get())
	}

	@Test fun failedReadStopsAfterTwoAttempts() = runBlocking {
		val count = AtomicInteger()
		val transport = OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor {
			count.incrementAndGet(); throw IOException("offline")
		}.build()
		val node = LightningNode(NodeConnection(endpoint = "https://node.invalid", credential = "00"), transport)
		try { node.info(); fail("Read must fail") } catch (_: IOException) {}
		assertEquals(2, count.get())
	}

	@Test fun cancellationClosesTheActiveRequestWithoutRetry() = runBlocking {
		val server = MockWebServer()
		server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
		server.start()
		val transport = OkHttpClient.Builder().retryOnConnectionFailure(false).build()
		try {
			val node = LightningNode(NodeConnection(endpoint = server.url("/").toString(), credential = "00"), transport)
			val job = launch { node.info() }
			withTimeout(5000) { while (server.requestCount == 0) delay(10) }
			job.cancelAndJoin()
			for (attempt in 0..100) {
				if (transport.dispatcher.runningCallsCount() == 0) break
				delay(10)
			}
			assertEquals(0, transport.dispatcher.runningCallsCount())
			assertEquals(1, server.requestCount)
		} finally { server.shutdown() }
	}
}
