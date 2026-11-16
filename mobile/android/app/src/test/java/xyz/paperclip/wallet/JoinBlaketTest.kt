package xyz.paperclip.wallet

import java.net.SocketTimeoutException
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class JoinBlaketTest {
	private fun pairingText(changes: Map<String, Any> = emptyMap()): String {
		val value = JSONObject().put("kind", "paperclip-jars-v1").put("scope", "jars_manage_v1").put("endpoint", "https://host.example.invalid")
			.put("wallet", "fixture.jmdat").put("token", "pj1_" + "a".repeat(64)).put("expires", 4_000_000_000L).put("certificate_sha256", "")
		changes.forEach { (key, value_) -> value.put(key, value_) }
		return "paperclip-jars:" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(value.toString().toByteArray())
	}
	@Test fun pairingRejectsUnsafeEndpointsScopeAndExpiry() {
		for (change in listOf(mapOf("endpoint" to "http://host.local"), mapOf("endpoint" to "https://user:secret@host.local"), mapOf("scope" to "all"),
			mapOf("expires" to 1), mapOf("wallet" to "../other"), mapOf("token" to "main-wallet-token"), mapOf("certificate_sha256" to "invalid"))) {
			assertThrows(IllegalArgumentException::class.java) { JoinBlaketPairing.parse(pairingText(change)) }
		}
		assertEquals("Jars pairing (redacted)", JoinBlaketPairing.parse(pairingText()).toString())
	}
	@Test fun pairedTransportUsesOnlyScopedProxyAndNeverReplays() = runBlocking {
		val pair = JoinBlaketPairing.parse(pairingText()); var calls = 0; var timeout = false
		val http = OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor {
			calls++; assertEquals("/api/v1/paired-jars/request", it.request().url.encodedPath); assertEquals("POST", it.request().method)
			val buffer = okio.Buffer(); it.request().body!!.writeTo(buffer); val body = JSONObject(buffer.readUtf8())
			assertEquals("status", body.getString("operation")); assertEquals(pair.wallet, body.getString("wallet"))
			assertFalse(body.has("token")); assertFalse(body.has("password")); assertNull(it.request().url.query)
			if (timeout) throw SocketTimeoutException("synthetic timeout")
			Response.Builder().request(it.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
				.body("""{"session":true,"wallet_name":"fixture.jmdat","maker_running":false,"coinjoin_in_process":false,"rescanning":false}""".toResponseBody()).build()
		}.build()
		val client = JoinBlaketClient(pair.connection, http, pair)
		client.status(pair.authorization()); assertEquals(1, calls)
		timeout = true
		try { client.status(pair.authorization()); fail() } catch (_: SocketTimeoutException) {}
		assertEquals(2, calls)
		try { client.unlock(pair.wallet, "synthetic"); fail() } catch (_: IllegalArgumentException) {}
		try { client.status(JoinBlaketAuthorization("other.jmdat", "synthetic")); fail() } catch (_: IllegalArgumentException) {}
		assertEquals(2, calls)
	}
	private fun recoveryCases() = org.json.JSONArray(checkNotNull(javaClass.getResourceAsStream("/jam-recovery.json")).bufferedReader().use { it.readText() })
	@Test fun recoveryMatchesSharedCases() {
		val cases = recoveryCases()
		for (index in 0 until cases.length()) {
			val item = cases.getJSONObject(index)
			val result = runCatching { JoinBlaketPayment.parse(item.getJSONObject("payment"), "fixture.jmdat") }
			assertEquals(item.getString("name"), item.getBoolean("valid"), result.isSuccess)
			result.getOrNull()?.let { assertFalse(it.label.lowercase().contains("successful")) }
		}
	}
	@Test fun recoveryChecksAreReadOnlyAndFailuresDoNotReplay() = runBlocking {
		val paths = mutableListOf<String>(); var code = 200
		val record = recoveryCases().getJSONObject(3).getJSONObject("payment")
		val http = OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor {
			val path = it.request().url.encodedPath; paths.add(path)
			assertEquals("GET", it.request().method); assertNull(it.request().url.query)
			val state = path == "/api/v1/session"
			Response.Builder().request(it.request()).protocol(Protocol.HTTP_1_1).code(if (state) 200 else code).message("Synthetic")
				.body((if (state) """{"session":true,"wallet_name":"fixture.jmdat"}""" else if (path.endsWith("/payments")) """{"payments":[$record]}""" else record.toString()).toResponseBody()).build()
		}.build()
		val client = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"), http)
		val auth = JoinBlaketAuthorization("fixture.jmdat", "synthetic-token")
		val rows = client.payments(auth); assertEquals(1, rows.size)
		assertEquals("unknown", client.checkPayment(rows[0].id, auth).state)
		assertEquals(4, paths.size)
		code = 504; paths.clear()
		try { client.checkPayment(rows[0].id, auth); fail() } catch (_: IllegalArgumentException) {}
		assertEquals(2, paths.size)
		paths.clear()
		try { client.checkPayment("../commit", auth); fail() } catch (_: IllegalArgumentException) {}
		assertTrue(paths.isEmpty())
		code = 404
		try { client.payments(auth); fail("Missing companion is not empty history") } catch (_: IllegalArgumentException) {}
	}

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
