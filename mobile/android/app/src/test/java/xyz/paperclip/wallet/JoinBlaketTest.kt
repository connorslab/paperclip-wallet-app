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
    @Test fun pairedBondInventoryUsesReadOnlyHostRoute() = runBlocking {
        val pair=JoinBlaketPairing.parse(pairingText())
        val fixtures=org.json.JSONArray(checkNotNull(javaClass.getResourceAsStream("/jam-bonds.json")).bufferedReader().use { it.readText() })
        val operations=mutableListOf<String>()
        val http=OkHttpClient.Builder().addInterceptor { chain ->
            assertEquals("/api/v1/paired-jars/request",chain.request().url.encodedPath)
            val buffer=okio.Buffer();chain.request().body!!.writeTo(buffer);val fields=JSONObject(buffer.readUtf8())
            val op=fields.getString("operation");operations.add(op)
            val result=if(op=="status") JSONObject().put("session",true).put("maker_running",false).put("coinjoin_in_process",false).put("rescanning",false).put("wallet_name","fixture.jmdat") else { assertEquals("bonds",op);fixtures.getJSONObject(0).getJSONObject("inventory") }
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("fixture").body(result.toString().toResponseBody()).build()
        }.build()
        val inventory=JoinBlaketClient(pair.connection,http,pair).bonds(pair.authorization())
        assertEquals(1,inventory.bonds.size);assertEquals(listOf("status","bonds"),operations)
    }

    @Test fun bondInventoryMatchesSharedCases() {
        val cases = org.json.JSONArray(checkNotNull(javaClass.getResourceAsStream("/jam-bonds.json")).bufferedReader().use { it.readText() })
        for(index in 0 until cases.length()) {
            val item=cases.getJSONObject(index)
            val result=runCatching { JoinBlaketBondInventory.parse(item.getJSONObject("inventory"),"fixture.jmdat") }
            assertEquals(item.getString("name"),item.getBoolean("valid"),result.isSuccess)
            result.getOrNull()?.let { inventory -> inventory.bonds.forEachIndexed { i,coin -> assertEquals(item.getJSONArray("withdrawable").getBoolean(i),coin.canWithdraw(inventory.chainTime)) } }
        }
    }

	@Test fun sendReviewMatchesSharedCases() {
		val draft = JoinBlaketSendDraft(0,"bcrt1qsyntheticrecipient",20000,1000,500,"a".repeat(64))
		val cases = org.json.JSONArray(checkNotNull(javaClass.getResourceAsStream("/jam-send-review.json")).bufferedReader().use { it.readText() })
		for (index in 0 until cases.length()) {
			val item = cases.getJSONObject(index)
			val result = runCatching { JoinBlaketSendReview.parse(item.getJSONObject("review"),"fixture.jmdat").validate(draft.copy(coinjoin=item.optBoolean("coinjoin",false),bondLocktime=if(item.has("bond_locktime")) item.getLong("bond_locktime") else null,bondOutpoint=if(item.has("bond_outpoint")) item.getString("bond_outpoint") else null),"fixture.jmdat","xbt-regtest:"+"c".repeat(64),2000000000) }
			assertEquals(item.getString("name"),item.getBoolean("valid"),result.isSuccess)
		}
		assertThrows(IllegalArgumentException::class.java) { JoinBlaketSendDraft(0,draft.destination,Long.MAX_VALUE,1000,1) }
		for (stamp in listOf(1L,4_099_766_401L)) assertThrows(IllegalArgumentException::class.java) { draft.copy(bondLocktime=stamp) }
		assertThrows(IllegalArgumentException::class.java) { draft.copy(coinjoin=true,bondLocktime=2100000000) }
	}
	@Test fun directSendBindsReviewAndNeverRepeatsLostCommit() = runBlocking {
		val auth = JoinBlaketAuthorization("fixture.jmdat","synthetic-token")
		val draft = JoinBlaketSendDraft(0,"bcrt1qsyntheticrecipient",20000,1000,500,"a".repeat(64))
		val cases = org.json.JSONArray(checkNotNull(javaClass.getResourceAsStream("/jam-send-review.json")).bufferedReader().use { it.readText() })
		val saved = cases.getJSONObject(0).getJSONObject("review").put("expires",java.time.Instant.now().epochSecond+200)
		var identity = "xbt-regtest:"+"c".repeat(64); var lost = false; var commits = 0
		val http = OkHttpClient.Builder().addInterceptor { chain ->
			val path = chain.request().url.encodedPath
			val result = when {
				path.endsWith("/identity") -> JSONObject().put("wallet",auth.wallet).put("identity",identity)
				path.endsWith("/capabilities") -> JSONObject().put("version",1).put("reviewed_direct_send",true)
				else -> saved
			}
			if (path.endsWith("/commit")) { commits++; saved.put("state","unknown"); if (lost) throw SocketTimeoutException("Synthetic lost response") }
			Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(result.toString().toResponseBody()).build()
		}.build()
		val c = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"),http)
		val review = c.prepareSend(draft,auth)
		identity = "xbt-regtest:"+"e".repeat(64)
		assertTrue(runCatching { c.commitSend(review,draft,auth) }.isFailure); assertEquals(0,commits)
		identity = review.walletIdentity; lost = true
		assertTrue(runCatching { c.commitSend(review,draft,auth) }.isFailure)
		assertEquals("unknown",c.commitSend(review,draft,auth).state); assertEquals(1,commits)
	}
	@Test fun coinJoinSendBindsReviewAndNeverRepeatsLostCommit() = runBlocking {
		val auth = JoinBlaketAuthorization("fixture.jmdat","synthetic-token")
		val draft = JoinBlaketSendDraft(0,"bcrt1qsyntheticrecipient",20000,1000,500,"a".repeat(64),coinjoin=true)
		val cases = org.json.JSONArray(checkNotNull(javaClass.getResourceAsStream("/jam-send-review.json")).bufferedReader().use { it.readText() })
		val saved = (0 until cases.length()).map { cases.getJSONObject(it) }.first { it.getString("name") == "reviewed CoinJoin" }.getJSONObject("review").put("expires",java.time.Instant.now().epochSecond+200)
		var supported = false; var prepares = 0
		var identity = "xbt-regtest:"+"c".repeat(64); var lost = false; var commits = 0
		val http = OkHttpClient.Builder().addInterceptor { chain ->
			val path = chain.request().url.encodedPath
			if (path.endsWith("/payments") && chain.request().method == "POST") {
				prepares++; val buffer = okio.Buffer(); chain.request().body!!.writeTo(buffer)
				val body = JSONObject(buffer.readUtf8()); check(body.getBoolean("coinjoin") && !body.getBoolean("rbf"))
			}
			val result = when {
				path.endsWith("/identity") -> JSONObject().put("wallet",auth.wallet).put("identity",identity)
				path.endsWith("/capabilities") -> JSONObject().put("version",if(supported) 2 else 1).put("reviewed_direct_send",true).put("coinjoin_payments",supported)
				else -> saved
			}
			if (path.endsWith("/commit")) { commits++; saved.put("state","unknown"); if (lost) throw SocketTimeoutException("Synthetic lost response") }
			Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(result.toString().toResponseBody()).build()
		}.build()
		val c = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"),http)
		assertTrue(runCatching { c.prepareSend(draft,auth) }.isFailure); assertEquals(0,prepares)
		supported = true
		val review = c.prepareSend(draft,auth)
		assertEquals(1,prepares)
		identity = "xbt-regtest:"+"e".repeat(64)
		assertTrue(runCatching { c.commitSend(review,draft,auth) }.isFailure); assertEquals(0,commits)
		identity = review.walletIdentity; lost = true
		assertTrue(runCatching { c.commitSend(review,draft,auth) }.isFailure)
		assertEquals("unknown",c.commitSend(review,draft,auth).state); assertEquals(1,commits)
	}
	@Test fun paymentPairingPreservesModeAndNeverRepeatsLostCommit() = runBlocking {
		for (mode in 0..3) {
			val coinjoin=mode==1; val bondTime:Long?=if(mode==3) 1800000000 else if(mode==2) 2100000000 else null
			val pair = JoinBlaketPairing.parse(pairingText(mapOf("scope" to "jars_pay_v1")))
			assertTrue(pair.canSend)
			val draft = JoinBlaketSendDraft(0,"bcrt1qsyntheticrecipient",20000,1000,500,"a".repeat(64),coinjoin,bondTime,if(mode==3) "1".repeat(64)+":0" else null)
			val cases=org.json.JSONArray(checkNotNull(javaClass.getResourceAsStream("/jam-send-review.json")).bufferedReader().use { it.readText() })
			val saved=(if (bondTime != null) (0 until cases.length()).map { cases.getJSONObject(it) }.first { it.getString("name") == if(mode==3) "reviewed bond withdrawal" else "reviewed bond funding" } else if (coinjoin) (0 until cases.length()).map { cases.getJSONObject(it) }.first { it.getString("name") == "reviewed CoinJoin" } else cases.getJSONObject(0)).getJSONObject("review").put("expires",java.time.Instant.now().epochSecond+200)
			val operations=mutableListOf<String>(); var revoked=false; var fundingSupported=false
			val http=OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
				assertEquals("/api/v1/paired-jars/request",chain.request().url.encodedPath)
				val buffer=okio.Buffer();chain.request().body!!.writeTo(buffer);val body=JSONObject(buffer.readUtf8())
				assertFalse(body.has("token"));assertFalse(body.has("password"));assertEquals(pair.wallet,body.getString("wallet"))
				val op=body.getString("operation");operations.add(op)
				var status=if(revoked) 401 else 200
				val result=when(op) {
					"identity" -> JSONObject().put("wallet",pair.wallet).put("identity","xbt-regtest:"+"c".repeat(64))
					"payment_capabilities" -> JSONObject().put("version",2).put("reviewed_direct_send",true).put("coinjoin_payments",true).put("bond_funding",fundingSupported).put("bond_withdrawal",fundingSupported)
					"prepare_payment" -> { assertEquals(bondTime,(body.getJSONObject("send").opt("bond_locktime") as? Number)?.toLong()); assertEquals(coinjoin,body.getJSONObject("send").getBoolean("coinjoin"));saved }
					"payment_review" -> saved
					"commit_payment" -> {
						assertEquals("xbt-regtest:"+"c".repeat(64),body.getString("wallet_identity"))
						assertEquals(saved.getString("approval"),body.getString("approval"))
						saved.put("state","unknown");status=504;JSONObject()
					}
					else -> error("Unexpected paired operation")
				}
				Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(status).message("fixture").body(result.toString().toResponseBody()).build()
			}.build()
			val client=JoinBlaketClient(pair.connection,http,pair); val auth=pair.authorization()
			if (bondTime != null) {
				assertTrue(runCatching { client.prepareSend(draft,auth) }.isFailure)
				assertFalse(operations.contains("prepare_payment"))
			}
			fundingSupported=true
			val review=client.prepareSend(draft,auth)
			assertFalse(operations.contains("commit_payment"))
			assertTrue(runCatching { client.commitSend(review,draft,auth) }.isFailure)
			assertEquals("unknown",client.commitSend(review,draft,auth).state)
			assertEquals(1,operations.count { it == "commit_payment" })
			revoked=true
			assertTrue(runCatching { client.commitSend(review,draft,auth) }.isFailure)
			assertEquals(1,operations.count { it == "commit_payment" })
		}
	}
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
	@Test fun relativeMakerFeesAndDiscardNeverFallBackOrReplay() = runBlocking {
		val auth = JoinBlaketAuthorization("fixture.jmdat", "synthetic-token")
		val connection = JoinBlaketConnection("https://fixture.invalid", "", "")
		var state = "prepared"; var failCancel = false
		val requests = mutableListOf<Pair<String, JSONObject?>>()
		val row = recoveryCases().getJSONObject(1).getJSONObject("payment")
		val http = OkHttpClient.Builder().addInterceptor { chain ->
			val request = chain.request(); val path = request.url.encodedPath
			val buffer = okio.Buffer(); request.body?.writeTo(buffer)
			val body = if (buffer.size > 0) JSONObject(buffer.readUtf8()) else null
			requests.add(path to body)
			val reply = when {
				path.endsWith("/session") -> """{"session":true,"wallet_name":"fixture.jmdat","maker_running":false,"coinjoin_in_process":false,"rescanning":false}"""
				path.endsWith("/maker/start") -> "{}"
				else -> JSONObject(row.toString()).put("state", if (path.endsWith("/cancel")) "cancelled" else state).toString()
			}
			Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(if (failCancel && path.endsWith("/cancel")) 504 else 200).message("fixture").body(reply.toResponseBody()).build()
		}.build()
		val client = JoinBlaketClient(connection, http)
		for (rate in JoinBlaketMakerFee.rates) {
			client.startMaker(100000,0,auth,rate)
			val body = requests.last().second!!
			assertEquals(rate,body.getString("cjfee_r")); assertEquals("0",body.getString("cjfee_a")); assertEquals("sw0reloffer",body.getString("ordertype"))
		}
		requests.clear()
		for ((fee,rate) in listOf(123L to null,100L to "0.00005",0L to "0.005%")) {
			try { client.startMaker(100000,fee,auth,rate); fail("Invalid terms") } catch (_: IllegalArgumentException) {}
		}
		assertTrue(requests.isEmpty()); assertEquals("0.005%",JoinBlaketMakerFee.label("0.00005"))
		val id = row.getString("id")
		assertEquals("cancelled",client.discardPayment(id,auth).state)
		assertEquals(1,requests.count { it.first.endsWith("/cancel") })
		for (next in listOf("submitting","unknown","submitted")) {
			state = next; requests.clear()
			try { client.discardPayment(id,auth); fail("Cannot discard submitted payment") } catch (_: IllegalArgumentException) {}
			assertFalse(requests.any { it.first.endsWith("/cancel") })
		}
		state = "prepared"; failCancel = true; requests.clear()
		try { client.discardPayment(id,auth); fail("Lost reply") } catch (_: Exception) {}
		assertEquals(1,requests.count { it.first.endsWith("/cancel") })
	}
	@Test fun pairedPercentageRemainsRelativeAndCannotDiscard() = runBlocking {
		val pair = JoinBlaketPairing.parse(pairingText())
		val requests = mutableListOf<JSONObject>()
		val http = OkHttpClient.Builder().addInterceptor { chain ->
			assertEquals("/api/v1/paired-jars/request", chain.request().url.encodedPath)
			val buffer = okio.Buffer(); chain.request().body!!.writeTo(buffer)
			requests.add(JSONObject(buffer.readUtf8()))
			Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("fixture")
				.body("""{"session":true,"wallet_name":"fixture.jmdat","maker_running":false,"coinjoin_in_process":false,"rescanning":false}""".toResponseBody()).build()
		}.build()
		val client = JoinBlaketClient(pair.connection, http, pair)
		client.startMaker(100000,0,pair.authorization(),"0.00005")
		val body = requests.last()
		assertEquals("start_maker",body.getString("operation"))
		assertEquals("0.00005",body.getString("relative_fee"))
		assertEquals(100000L,body.getLong("minimum_sat")); assertFalse(body.has("fee_sat"))
		requests.clear()
		try { client.discardPayment("a".repeat(64),pair.authorization()); fail("Management grant cannot discard") } catch (_: IllegalArgumentException) {}
		assertTrue(requests.isEmpty())
	}
	@Test fun managementPairingCannotPreparePayments() = runBlocking {
		val pair = JoinBlaketPairing.parse(pairingText())
		var calls = 0
		val http = OkHttpClient.Builder().addInterceptor { calls++; error("No paired payment transport") }.build()
		val client = JoinBlaketClient(pair.connection,http,pair)
		assertTrue(runCatching { client.prepareSend(JoinBlaketSendDraft(0,"bcrt1qsyntheticrecipient",20000,1000,500),pair.authorization()) }.isFailure)
		assertEquals(0,calls)
	}
	@Test fun marketSummaryRejectsWrongAmountAndExpires() {
		val now = java.time.Instant.now().epochSecond
		val row = JSONObject().put("amount_sat",100000L).put("fetched_at",now).put("book_updated_at",now).put("status","fresh").put("maker_count",2).put("median_fee_sat","75.5")
		val result = JoinBlaketMarket.parse(row,100000,now)
		assertTrue(result.summary(now+121).contains("stale"))
		assertThrows(IllegalArgumentException::class.java) { JoinBlaketMarket.parse(row,200000,now) }
	}
	private fun recoveryCases() = org.json.JSONArray(checkNotNull(javaClass.getResourceAsStream("/jam-recovery.json")).bufferedReader().use { it.readText() })
	@Test fun recoveryMatchesSharedCases() {
		val cases = recoveryCases()
		for (index in 0 until cases.length()) {
			val item = cases.getJSONObject(index)
			val result = runCatching { JoinBlaketPayment.parse(item.getJSONObject("payment"), "fixture.jmdat") }
			assertEquals(item.getString("name"), item.getBoolean("valid"), result.isSuccess)
			result.getOrNull()?.let {
				assertFalse(it.label.lowercase().contains("successful"))
				it.quote?.takeIf { q -> q.purpose != "send" }?.let { q ->
					assertEquals(if (q.bondLocktime == null) "Unavailable — check your Jam host" else "2030-01-01 00:00 UTC",q.bondUnlockDescription)
				}
			}
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
