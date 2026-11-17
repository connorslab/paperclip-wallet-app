package xyz.paperclip.wallet

import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Synthetic session only: no transport, wallet keys or funds. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
class JoinBlaketLayoutTest {
	@Test fun jarSendPreservesCoinJoinChoiceAndRecoversLostCommit() {
		val paths = java.util.Collections.synchronizedList(mutableListOf<String>())
		var saved = JSONObject()
		val http = okhttp3.OkHttpClient.Builder().addInterceptor { chain ->
			val path = chain.request().url.encodedPath; paths.add(path)
			val result = when {
				path.endsWith("/identity") -> JSONObject().put("wallet","fixture.jmdat").put("identity","xbt-regtest:"+"c".repeat(64))
				path.endsWith("/capabilities") -> JSONObject().put("version",2).put("reviewed_direct_send",true).put("coinjoin_payments",true)
				path.endsWith("/payments") -> {
					val buffer = okio.Buffer(); chain.request().body!!.writeTo(buffer); val request = JSONObject(buffer.readUtf8())
					check(request.getString("purpose") == "send" && request.getLong("amount_sat") == 20000L && request.getBoolean("coinjoin") && !request.getBoolean("rbf"))
					saved = JSONObject().put("id",request.getString("id")).put("state","prepared").put("expires",java.time.Instant.now().epochSecond+200).put("approval","b".repeat(64))
						.put("quote",JSONObject().put("wallet","fixture.jmdat").put("wallet_identity","xbt-regtest:"+"c".repeat(64)).put("network","xbt-regtest").put("rbf",false).put("coinjoin",true).put("maker_fee_sat",100).put("mining_fee_sat",100).put("network_fee_sat",100).put("maker_count",2).put("broadcast_policy","self")
							.put("jar",0).put("purpose","send").put("destination",request.getString("destination")).put("txid","d".repeat(64)).put("amount_sat",20000).put("fee_sat",200).put("total_sat",20200))
					saved
				}
				path.endsWith("/commit") -> throw java.net.SocketTimeoutException("Synthetic lost commit")
				else -> saved
			}
			okhttp3.Response.Builder().request(chain.request()).protocol(okhttp3.Protocol.HTTP_1_1).code(200).message("fixture").body(okhttp3.ResponseBody.create(null,result.toString())).build()
		}.build()
		var activity = false
		val client = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"),http)
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) {
			androidx.compose.material3.ModalBottomSheet(onDismissRequest={}, containerColor=MaterialTheme.colorScheme.background,
				sheetState=androidx.compose.material3.rememberModalBottomSheetState(skipPartiallyExpanded=true)) {
				JarsSendPage(client,JoinBlaketAuthorization("fixture.jmdat","synthetic-token"),0,"Apricot",close={},activity={activity=true})
			}
		} }
		compose.onNodeWithTag("jars-send-coinjoin").performScrollTo().performClick()
		compose.onNodeWithText("Review payment").performScrollTo().assertIsEnabled()
		assertTrue(paths.isEmpty())
		compose.onNodeWithText("XBT address").performScrollTo().performTextInput("bcrt1qsyntheticrecipient")
		compose.onNodeWithText("Amount (sats)").performScrollTo().performTextInput("20000")
		compose.onNodeWithText("Review payment").performScrollTo().performClick()
		compose.waitUntil(10000) { compose.onAllNodesWithText("Send payment").fetchSemanticsNodes().isNotEmpty() }
		compose.onNodeWithText("Maker fees").assertExists(); compose.onNodeWithText("Your mining fee").assertExists()
		compose.waitUntil(5000) {
			InstrumentationRegistry.getInstrumentation().uiAutomation.windows.none { it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD }
		}
		capture("android-jar-coinjoin-review")
		compose.onNodeWithText("Send payment").performScrollTo().performClick()
		compose.waitUntil(10000) { compose.onAllNodesWithText("Synthetic lost commit").fetchSemanticsNodes().isNotEmpty() }
		compose.onNodeWithText("View payment activity").performScrollTo().performClick()
		assertTrue(activity); assertEquals(1,paths.count { it.endsWith("/commit") })
		compose.onNodeWithText("Send payment").assertDoesNotExist()
	}
	@Test fun pairingReviewShowsScopeAndCancelDoesNotConnect() {
		val state = JoinBlaketUiState()
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
				JoinBlaketPage(state)
			}
		} } }
		val payload = JSONObject().put("kind", "paperclip-jars-v1").put("scope", "jars_manage_v1")
			.put("endpoint", "https://host.example.invalid").put("wallet", "fixture.jmdat").put("token", "pj1_" + "a".repeat(64))
			.put("expires", 4_000_000_000L).put("certificate_sha256", "")
		val code = "paperclip-jars:" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(payload.toString().toByteArray())
		compose.onNodeWithText("Paste pairing code").performScrollTo().performTextInput(code)
		compose.onNodeWithText("Review connection").performScrollTo().performClick()
		compose.onNodeWithText("https://host.example.invalid").assertExists()
		compose.onNodeWithText("fixture.jmdat").assertExists()
		compose.onNodeWithText("Verify and save connection").performScrollTo().assertIsDisplayed()
		capture("android-pairing-review")
		compose.onNodeWithText("Cancel").performScrollTo().performClick()
		compose.onNodeWithText("Scan pairing code").assertExists()
		compose.runOnIdle { assertNull(state.client.value); assertNull(state.authorization.value); assertNull(state.session.value) }
	}
	@get:Rule val compose = createComposeRule()
	@Test fun recoveryPreservesUnknownOnTimeoutAndOnlyObserves() {
		val paths = java.util.Collections.synchronizedList(mutableListOf<String>())
		val checks = java.util.concurrent.atomic.AtomicInteger()
		val id = "a".repeat(64)
		val http = okhttp3.OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor {
			val path = it.request().url.encodedPath; paths.add(path)
			check(it.request().method == "GET")
			val status = path.endsWith("/session")
			val checking = path.endsWith("/$id")
			val count = if (checking) checks.incrementAndGet() else checks.get()
			val record = """{"id":"$id","state":"${if (count > 1) "submitted" else "unknown"}","quote":{"wallet":"fixture.jmdat","jar":2,"purpose":"send","destination":"bc1qsyntheticdestination","txid":"${"b".repeat(64)}","amount_sat":20000,"fee_sat":140,"total_sat":20140}}"""
			val body = if (status) """{"session":true,"wallet_name":"fixture.jmdat"}""" else if (checking) record else """{"payments":[$record]}"""
			okhttp3.Response.Builder().request(it.request()).protocol(okhttp3.Protocol.HTTP_1_1)
				.code(if (checking && count == 1) 504 else 200).message("Synthetic")
				.body(okhttp3.ResponseBody.create(null, body)).build()
		}.build()
		val state = JoinBlaketUiState().apply {
			wallet.value = "Sample Jars · no live funds"
			session.value = JSONObject().put("session", true).put("maker_running", false).put("coinjoin_in_process", false).put("rescanning", false)
			client.value = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"), http)
			authorization.value = JoinBlaketAuthorization("fixture.jmdat", "synthetic-token")
		}
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp)) { JoinBlaketPage(state) }
		} } }
		compose.onNodeWithText("Jars payment activity").performScrollTo().performClick()
		compose.waitUntil(10000) { compose.onAllNodesWithText("Status unknown").fetchSemanticsNodes().isNotEmpty() }
		compose.onNodeWithText("Check status").assertIsDisplayed().performClick()
		compose.waitUntil(10000) { compose.onAllNodesWithText("Could not check payment status. Check your connection and try again.").fetchSemanticsNodes().isNotEmpty() }
		compose.onNodeWithText("Status unknown").assertIsDisplayed()
		assertEquals(1, checks.get())
		capture("android-jam-recovery")
		compose.onNodeWithText("Check status").performClick()
		compose.waitUntil(10000) { compose.onAllNodesWithText("Submitted").fetchSemanticsNodes().isNotEmpty() }
		compose.onNodeWithText("Check status").assertDoesNotExist()
		compose.onNodeWithText("Seen by your node. Confirmation has not been checked.").assertExists()
		assertEquals(2, checks.get())
		assertTrue(paths.all { it == "/api/v1/session" || it == "/api/v1/wallet/fixture.jmdat/paperclip/payments" || it == "/api/v1/wallet/fixture.jmdat/paperclip/payments/$id" })
	}

	@Test fun compactJarSelectionShowsActionsAndKeepsAllAccountsReachable() {
		val state = JoinBlaketUiState().apply {
			wallet.value = "Sample Jars wallet · no live funds"
			session.value = JSONObject().put("session", true).put("maker_running", false)
				.put("coinjoin_in_process", false).put("rescanning", false)
			jars.value = listOf("Apricot", "Blueberry", "Cherry", "Date", "Elderberry").mapIndexed { id, name ->
				JSONObject().put("id", id).put("name", name).put("total_sat", if (id == 0) 200000 else 0)
					.put("confirmed_sat", if (id == 0) 200000 else 0).put("pending_sat", 0)
					.put("frozen_sat", 0).put("bond_sat", 0)
			}
		}
		val dark = androidx.compose.runtime.mutableStateOf(true)
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(dark.value)) { Surface(color = MaterialTheme.colorScheme.background) {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
				androidx.compose.material3.Text("Jars", style = MaterialTheme.typography.headlineLarge)
				JoinBlaketPage(state)
			}
		} } }
		compose.onNodeWithTag("jar-0").assertIsSelected()
		for (id in 0..4) compose.onNodeWithTag("jar-$id").assertIsDisplayed()
		val first = compose.onNodeWithTag("jar-0").fetchSemanticsNode().boundsInRoot
		val second = compose.onNodeWithTag("jar-1").fetchSemanticsNode().boundsInRoot
		val last = compose.onNodeWithTag("jar-4").fetchSemanticsNode().boundsInRoot
		assertEquals(first.top, second.top, 2f)
		assertEquals((first.left + second.right) / 2, last.center.x, 2f)
		assertEquals(first.width, last.width, 2f)
		capture("android-jars")
		compose.onNodeWithTag("jar-4").performClick().assertIsSelected()
		compose.onNodeWithText("Receive into Elderberry").assertExists()
		compose.runOnIdle { assertEquals(4, state.selected.intValue); assertNull(state.client.value); dark.value = false }
		for (id in 0..4) compose.onNodeWithTag("jar-$id").assertIsDisplayed()
		compose.onNodeWithTag("jar-4").assertIsSelected()
		capture("android-jars-light")
	}

	@Test fun bondReviewNamesWalletAndDateWithoutFunding() {
		val state = JoinBlaketUiState().apply {
			wallet.value = "Fixture Jars wallet"
			session.value = JSONObject().put("session", true).put("maker_running", false)
				.put("coinjoin_in_process", false).put("rescanning", false)
			bondMonth.value = "2099-12"
		}
		compose.setContent { MaterialTheme { Surface {
			Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) { JoinBlaketPage(state) }
		} } }
		compose.onNodeWithText("Fidelity bond").performScrollTo().performClick()
		compose.onNodeWithText("Review bond address").performScrollTo().performClick()
		compose.onNodeWithText("Create bond address?").assertIsDisplayed()
		compose.onNodeWithText("Wallet: Fixture Jars wallet. Coins sent here will be locked until 2099-12-01 at 00:00 UTC. Creating the address sends no funds. Review the amount and mining fee separately when funding. Earnings are not guaranteed.").assertIsDisplayed()
		compose.onNodeWithText("Cancel").performClick()
		compose.onNodeWithText("Create bond address?").assertDoesNotExist()
		compose.runOnIdle {
			assertNull(state.client.value)
			assertNull(state.bondAddress.value)
			state.bondMonth.value = "2020-01"
		}
		compose.onNodeWithText("Review bond address").performScrollTo().performClick()
		compose.onNodeWithText("Choose a future month before 2100. Bonds unlock on its first day at 00:00 UTC.").performScrollTo().assertIsDisplayed()
	}

	@Test fun percentageAndMarketComparisonKeepUserFeeAndNeverStartMaker() {
		val paths = java.util.Collections.synchronizedList(mutableListOf<String>())
		val http = okhttp3.OkHttpClient.Builder().addInterceptor { chain ->
			val path = chain.request().url.encodedPath; paths.add(path)
			check(chain.request().method == "GET")
			val now = java.time.Instant.now().epochSecond
			val body = when (path) {
				"/api/v1/session" -> """{"session":true,"wallet_name":"fixture.jmdat"}"""
				"/api/v1/paperclip/market/100000" -> """{"amount_sat":100000,"fetched_at":$now,"book_updated_at":$now,"status":"fresh","maker_count":2,"median_fee_sat":"75.5"}"""
				else -> error("Unexpected request")
			}
			okhttp3.Response.Builder().request(chain.request()).protocol(okhttp3.Protocol.HTTP_1_1).code(200).message("fixture")
				.body(okhttp3.ResponseBody.create(null,body)).build()
		}.build()
		val state = JoinBlaketUiState().apply {
			wallet.value = "Fixture Jars wallet"
			session.value = JSONObject().put("session",true).put("maker_running",false)
			client.value = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"),http)
			authorization.value = JoinBlaketAuthorization("fixture.jmdat","synthetic-token")
		}
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp)) { JoinBlaketPage(state) }
		} } }
		compose.onNodeWithText("Percentage").assertDoesNotExist()
		compose.onNodeWithText("Maker settings").performScrollTo().performClick()
		compose.onNodeWithText("Percentage").performScrollTo().performClick()
		compose.onNodeWithText("Your fee: 0.005%").performScrollTo().assertIsDisplayed()
		compose.onNodeWithText("At 1,000,000 sats, your fee is 50 sats.").assertExists()
		compose.onNodeWithText("Ready: Amount and fee valid").assertDoesNotExist()
		compose.onNodeWithText("Setup checks ·",substring=true).performScrollTo().performClick()
		compose.onNodeWithText("Ready: Amount and fee valid").performScrollTo().assertIsDisplayed()
		compose.onNodeWithText("Setup checks ·",substring=true).performScrollTo().performClick()

		capture("android-maker-settings")
		compose.onNodeWithText("Done").performClick()
		compose.onNodeWithText("Market fees").performScrollTo().performClick()
		compose.onNodeWithText("Refresh market fees").performScrollTo().performClick()
		compose.waitUntil(10000) { compose.onAllNodesWithText("Median maker fee: 75.5 sats",substring=true).fetchSemanticsNodes().isNotEmpty() }
		compose.onNodeWithText("Median maker fee: 75.5 sats",substring=true).performScrollTo().assertIsDisplayed()
		capture("android-maker-market")
		compose.onNodeWithText("Done").performClick()
		compose.onNodeWithText("Maker settings").performScrollTo().performClick()
		compose.onNodeWithText("Your fee: 0.005%").performScrollTo().assertIsDisplayed()
		compose.onNodeWithText("Done").performClick()
		compose.onNodeWithText("How earning works").performScrollTo().performClick()
		compose.onNodeWithText("JoinBlaket’s default takers require a fidelity bond.",substring=true).performScrollTo().assertIsDisplayed()
		assertEquals(listOf("/api/v1/session","/api/v1/paperclip/market/100000"),paths.toList())
	}

	private fun capture(name: String) {
		compose.waitForIdle()
		val instrumentation = InstrumentationRegistry.getInstrumentation()
		instrumentation.waitForIdleSync()
		val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
		File(instrumentation.targetContext.getExternalFilesDir(null), "$name.png").outputStream().use {
			image.compress(Bitmap.CompressFormat.PNG, 100, it)
		}
		image.recycle()
	}
}
