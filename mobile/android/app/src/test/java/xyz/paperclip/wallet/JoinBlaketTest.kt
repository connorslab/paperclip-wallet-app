package xyz.paperclip.wallet

import java.net.SocketTimeoutException
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class JoinBlaketTest {
	@Test fun unlockPassphraseIsExplicitAndNeverPutInUrl() = runBlocking {
		val bodies = mutableListOf<org.json.JSONObject>()
		val http = OkHttpClient.Builder().addInterceptor {
			assertNull(it.request().url.query)
			val buffer = okio.Buffer(); it.request().body!!.writeTo(buffer)
			bodies.add(org.json.JSONObject(buffer.readUtf8()))
			Response.Builder().request(it.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
				.body("""{"walletname":"wallet.jmdat","token":"synthetic-token"}""".toResponseBody()).build()
		}.build()
		val client = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"), http)
		client.unlock("wallet.jmdat", "synthetic-password", "synthetic-passphrase")
		assertEquals("synthetic-passphrase", bodies[0].getString("bip39_passphrase"))
		assertEquals("synthetic-password", bodies[0].getString("password"))
		client.unlock("wallet.jmdat", "synthetic-password")
		assertFalse(bodies[1].has("bip39_passphrase"))
	}
	@Test fun receiveUsesJarAndDoesNotReplayFailedGetMutation() = runBlocking {
		var requests = 0
		val http = OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor {
			requests++
			assertEquals("/api/v1/wallet/wallet.jmdat/address/new/3", it.request().url.encodedPath)
			throw SocketTimeoutException("synthetic timeout")
		}.build()
		val client = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"), http)
		try { client.receiveAddress(3, JoinBlaketAuthorization("wallet.jmdat", "synthetic-token")); fail() }
		catch (_: SocketTimeoutException) {}
		assertEquals(1, requests)
	}
	@Test fun otherWalletStopsBeforeFetchingCoins() = runBlocking {
		var requests = 0
		val http = OkHttpClient.Builder().addInterceptor {
			requests++
			Response.Builder().request(it.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
				.body("""{"session":true,"wallet_name":"other.jmdat"}""".toResponseBody()).build()
		}.build()
		val client = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"), http)
		try { client.coins(JoinBlaketAuthorization("expected.jmdat", "synthetic-token")); fail() }
		catch (_: IllegalArgumentException) {}
		assertEquals(1, requests)
	}
	@Test fun connectionRequiresTrustAndExplicitOnionRoute() {
		for (url in listOf("http://start.local:28183", "https://example.onion", "https://user:password@jam.example")) {
			assertThrows(IllegalArgumentException::class.java) { JoinBlaketConnection(url).validate() }
		}
		JoinBlaketConnection("https://start.local:28183").validate()
		assertFalse(JoinBlaketAuthorization("wallet.jmdat", "synthetic-secret").toString().contains("synthetic-secret"))
	}
	@Test fun invalidJarAndEscapingWalletCannotSendRequest() = runBlocking {
		var requests = 0
		val http = OkHttpClient.Builder().addInterceptor { requests++; error("Must not connect") }.build()
		val client = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"), http)
		for ((jar, wallet) in listOf(5 to "wallet.jmdat", 0 to "../other")) {
			try { client.receiveAddress(jar, JoinBlaketAuthorization(wallet, "synthetic-token")); fail() }
			catch (_: IllegalArgumentException) {}
		}
		assertEquals(0, requests)
	}
}
