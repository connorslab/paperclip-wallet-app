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
	@Test fun bondMonthHasStrictUtcFutureBoundary() {
		val now = java.time.Instant.parse("2030-05-01T00:00:00Z")
		for (month in listOf("2030-05", "2030-04", "2030-00", "2030-13", "2030-6", "2100-01", "2019-12", "2031-01/other", "２０３１-01")) {
			assertThrows(month, IllegalArgumentException::class.java) { JoinBlaketBond.validate(month, now) }
		}
		for (month in listOf("2030-06", "2032-02", "2099-12")) JoinBlaketBond.validate(month, now)
	}
	@Test fun bondRegistersOnlyReviewedMonthAndDoesNotReplay() = runBlocking {
		val paths = mutableListOf<String>(); var failAddress = false
		val http = OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor {
			val path = it.request().url.encodedPath; paths.add(path)
			assertEquals("GET", it.request().method); assertNull(it.request().url.query)
			val state = path == "/api/v1/session"
			if (!state && failAddress) throw SocketTimeoutException("synthetic address timeout")
			Response.Builder().request(it.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
				.body((if (state) """{"session":true,"wallet_name":"wallet.jmdat","coinjoin_in_process":false,"rescanning":false}""" else """{"address":"bc1qsyntheticbond"}""").toResponseBody()).build()
		}.build()
		val client = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"), http)
		val auth = JoinBlaketAuthorization("wallet.jmdat", "synthetic-token")
		assertEquals("bc1qsyntheticbond", client.bondAddress("2099-12", auth))
		assertEquals(listOf("/api/v1/session", "/api/v1/wallet/wallet.jmdat/address/timelock/new/2099-12"), paths)
		paths.clear(); failAddress = true
		try { client.bondAddress("2099-12", auth); fail() } catch (_: SocketTimeoutException) {}
		assertEquals(2, paths.size)
		paths.clear()
		try { client.bondAddress("2020-01", auth); fail() } catch (_: IllegalArgumentException) {}
		assertTrue(paths.isEmpty())
		try { client.bondAddress("2099-12", JoinBlaketAuthorization("other.jmdat", "synthetic-token")); fail() } catch (_: IllegalArgumentException) {}
		assertEquals(listOf("/api/v1/session"), paths)
	}
	@Test fun makerReadinessMatchesSharedCases() {
		val text = checkNotNull(javaClass.getResourceAsStream("/maker-readiness.json")).bufferedReader().use { it.readText() }
		val cases = org.json.JSONArray(text)
		for (index in 0 until cases.length()) {
			val item = cases.getJSONObject(index); val jars = item.getJSONArray("jars")
			val result = JoinBlaketMakerReadiness.evaluate(item.getString("minimum"), item.getString("fee"),
				(0 until jars.length()).map { jars.getJSONObject(it) }, item.optJSONObject("session"), item.getBoolean("needsRefresh"))
			val actual = mapOf("terms" to result.terms, "funds" to result.funds, "bond" to result.bond, "server" to result.server, "fresh" to result.fresh, "canStart" to result.canStart)
			for ((key, value) in actual) assertEquals(item.getString("name") + ": " + key, item.getJSONObject("expected").getBoolean(key), value)
		}
	}

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
