package xyz.paperclip.wallet

import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.provider.MediaStore
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
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
	@Test fun bondHeaderKeepsCloseVisibleWithLargeText() {
		var closed = false
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) {
			val density = androidx.compose.ui.platform.LocalDensity.current
			androidx.compose.runtime.CompositionLocalProvider(
				androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(density.density, 2f),
				LocalContentColor provides MaterialTheme.colorScheme.onBackground,
			) {
				Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
					Box(Modifier.width(320.dp).fillMaxHeight().align(androidx.compose.ui.Alignment.TopCenter).safeDrawingPadding().testTag("large-jars-page")) {
						JarsSendPage(JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"),
							okhttp3.OkHttpClient.Builder().addInterceptor { throw java.io.IOException("No transport in layout fixture") }.build()),
							JoinBlaketAuthorization("fixture.jmdat","synthetic-token"),0,"Apricot",close={closed=true},activity={},bond=Pair("bcrt1qsyntheticrecipient","2099-12"))
					}
				}
			}
		} }
		val page = compose.onNodeWithTag("large-jars-page").fetchSemanticsNode().boundsInRoot
		for (label in listOf("Fund fidelity bond", "Close")) {
			val node = compose.onNodeWithText(label).assertIsDisplayed()
			val bounds = node.fetchSemanticsNode().boundsInRoot
			assertTrue(bounds.left >= page.left && bounds.right <= page.right)
			val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
			node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
			assertTrue(layouts.isNotEmpty())
			for (layout in layouts) {
				assertFalse("$label is clipped vertically", layout.didOverflowHeight)
				// Layout size is rounded to pixels; compare the rendered line extents.
				for (line in 0 until layout.lineCount) {
					assertTrue("$label is clipped on the left", layout.getLineLeft(line) >= -1f)
					assertTrue("$label is clipped on the right: ${layout.getLineRight(line)} > ${layout.size.width}", layout.getLineRight(line) <= layout.size.width + 1f)
				}
			}
		}
		compose.waitForIdle()
		capture("android-jars-large-text-header")
		compose.onNodeWithText("Close").performClick()
		assertTrue(closed)
	}
	@Test fun jarSendPreservesCoinJoinChoiceAndRecoversLostCommit() = reviewedPayment(false)
	@Test fun bondFundingKeepsDateAndRecoversLostCommit() = reviewedPayment(true)
	@Test fun bondWithdrawalReviewsNetValueAndNeverRepeatsLostCommit() = reviewedPayment(false, true)
	private fun reviewedPayment(bond: Boolean, withdrawal: Boolean = false) {
		val paths = java.util.Collections.synchronizedList(mutableListOf<String>())
		var saved = JSONObject()
		val http = okhttp3.OkHttpClient.Builder().addInterceptor { chain ->
			val path = chain.request().url.encodedPath; paths.add(path)
			val result = when {
				path.endsWith("/identity") -> JSONObject().put("wallet","fixture.jmdat").put("identity","xbt-regtest:"+"c".repeat(64))
				path.endsWith("/capabilities") -> JSONObject().put("version",2).put("reviewed_direct_send",true).put("coinjoin_payments",true).put("bond_funding",true).put("bond_withdrawal",true)
				path.endsWith("/payments") -> {
					val buffer = okio.Buffer(); chain.request().body!!.writeTo(buffer); val request = JSONObject(buffer.readUtf8())
					check(request.getString("purpose") == (if(withdrawal) "withdraw_bond" else if(bond) "fund_bond" else "send") && request.getLong("amount_sat") == (if(withdrawal) 0L else 20000L) && request.getBoolean("coinjoin") == (!bond && !withdrawal) && request.getBoolean("rbf") == (bond || withdrawal))
					saved = JSONObject().put("id",request.getString("id")).put("state","prepared").put("expires",java.time.Instant.now().epochSecond+200).put("approval","b".repeat(64))
						.put("quote",JSONObject().put("wallet","fixture.jmdat").put("wallet_identity","xbt-regtest:"+"c".repeat(64)).put("network","xbt-regtest").put("rbf",bond || withdrawal).put("coinjoin",!bond && !withdrawal).put("maker_fee_sat",100).put("mining_fee_sat",100).put("network_fee_sat",100).put("maker_count",2).put("broadcast_policy","self")
							.put("jar",0).put("purpose",if(withdrawal) "withdraw_bond" else if(bond) "fund_bond" else "send").apply { if(bond || withdrawal) put("bond_locktime",request.getLong("bond_locktime"));if(withdrawal) put("bond_outpoint","1".repeat(64)+":0") }.put("destination",request.getString("destination")).put("txid","d".repeat(64)).put("amount_sat",if(withdrawal) 19800 else 20000).put("fee_sat",200).put("total_sat",if(withdrawal) 20000 else 20200))
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
				JarsSendPage(client,JoinBlaketAuthorization("fixture.jmdat","synthetic-token"),0,"Apricot",close={},activity={activity=true},bond=if(bond) Pair("bcrt1qsyntheticrecipient","2099-12") else null,withdrawal=if(withdrawal) JoinBlaketBondCoin("1".repeat(64)+":0",20000,1800000000,6,false,true) else null)
			}
		} }
		if(bond || withdrawal) compose.onNodeWithTag("jars-send-coinjoin").assertDoesNotExist() else compose.onNodeWithTag("jars-send-coinjoin").performScrollTo().performClick()
		compose.onNodeWithText("Review payment").performScrollTo().assertIsEnabled()
		assertTrue(paths.isEmpty())
		if(bond) compose.onNodeWithText("XBT address").assertDoesNotExist() else compose.onNodeWithText("XBT address").performScrollTo().performTextInput("bcrt1qsyntheticrecipient")
		if(withdrawal) compose.onNodeWithText("Amount (sats)").assertDoesNotExist() else compose.onNodeWithText("Amount (sats)").performScrollTo().performTextInput("20000")
		compose.onNodeWithText("Review payment").performScrollTo().performClick()
		try {
			compose.waitUntil(10000) { compose.onAllNodes(hasText(if(withdrawal) "Withdraw bond" else if(bond) "Fund bond" else "Send payment") and hasClickAction()).fetchSemanticsNodes().isNotEmpty() }
		} catch (failure: ComposeTimeoutException) {
			// Preserve the actual failed page before later tests replace the window.
			// This fixture has only synthetic values and no live transport or keys.
			runCatching { saveScreenshot("android-jars-review-timeout") }
			val routeCounts = synchronized(paths) { paths.groupingBy { it.substringAfterLast('/') }.eachCount() }
			throw AssertionError("Synthetic review did not appear; requests=$routeCounts; " +
				runCatching { compose.onRoot(useUnmergedTree = true).printToString().take(12000) }.getOrDefault("UI unavailable"), failure)
		}
		if(withdrawal) compose.onNodeWithText("19,800 sats").assertExists() else if(bond) compose.onNodeWithText("2099-12-01 00:00 UTC").assertExists() else { compose.onNodeWithText("Maker fees").assertExists(); compose.onNodeWithText("Your mining fee").assertExists() }
		compose.waitUntil(5000) {
			InstrumentationRegistry.getInstrumentation().uiAutomation.windows.none { it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD }
		}
		capture(if(withdrawal) "android-bond-withdrawal-review" else if(bond) "android-bond-funding-review" else "android-jar-coinjoin-review")
		compose.onNode(hasText(if(withdrawal) "Withdraw bond" else if(bond) "Fund bond" else "Send payment") and hasClickAction()).performScrollTo().performClick()
		compose.waitUntil(10000) { compose.onAllNodesWithText("Synthetic lost commit").fetchSemanticsNodes().isNotEmpty() }
		compose.onNodeWithText("View payment activity").performScrollTo().performClick()
		assertTrue(activity); assertEquals(1,paths.count { it.endsWith("/commit") })
		compose.onNode(hasText(if(withdrawal) "Withdraw bond" else if(bond) "Fund bond" else "Send payment") and hasClickAction()).assertDoesNotExist()
	}
	@Test fun pairingReviewShowsScopeAndCancelDoesNotConnect() = checkPairingReview("jars_manage_v1", "Sending, key export and your main wallet are not included.")
	@Test fun paymentPairingReviewExplainsSpendingAndCancelDoesNotConnect() = checkPairingReview("jars_pay_v1", "Allows managing and sending funds")
	@Test fun torPairingReviewShowsBuiltInTorAndCancelDoesNotConnect() = checkPairingReview("jars_manage_v1", "Sending, key export and your main wallet are not included.", "http://" + "a".repeat(56) + ".onion")
	private fun checkPairingReview(scope: String, permission: String, endpoint: String = "https://host.example.invalid") {
		val state = JoinBlaketUiState()
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
				JoinBlaketPage(state)
			}
		} } }
		val payload = JSONObject().put("kind", "paperclip-jars-v1").put("scope", scope)
			.put("endpoint", endpoint).put("wallet", "fixture.jmdat").put("token", "pj1_" + "a".repeat(64))
			.put("expires", 4_000_000_000L).put("certificate_sha256", "")
		val code = "paperclip-jars:" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(payload.toString().toByteArray())
		compose.onNodeWithText("Paste pairing code").performScrollTo().performTextInput(code)
		compose.onNodeWithText("Review connection").performScrollTo().performClick()
		compose.onNodeWithText(endpoint).assertExists()
		compose.onNodeWithText(if (endpoint.contains(".onion")) "Built-in Tor" else "HTTPS").assertExists()
		compose.onNodeWithText("fixture.jmdat").assertExists()
		compose.onNodeWithText(permission, substring = true).assertExists()
		compose.onNodeWithText("Verify and save connection").performScrollTo().assertIsDisplayed()
		capture("android-pairing-review")
		compose.onNodeWithText("Cancel").performScrollTo().performClick()
		compose.onNodeWithText("Scan pairing code").assertExists()
		compose.runOnIdle { assertNull(state.client.value); assertNull(state.authorization.value); assertNull(state.session.value) }
	}
	@get:Rule val compose = createComposeRule()
	@Test fun changingAuthorizationClosesPaymentHistoryBeforeAnotherLookup() {
		val paths = java.util.Collections.synchronizedList(mutableListOf<String>())
		val http = okhttp3.OkHttpClient.Builder().addInterceptor { chain ->
			val path = chain.request().url.encodedPath; paths.add(path)
			check(chain.request().method == "GET")
			val body = if (path.endsWith("/session"))
				"""{"session":true,"wallet_name":"fixture.jmdat"}""" else """{"payments":[]}"""
			okhttp3.Response.Builder().request(chain.request()).protocol(okhttp3.Protocol.HTTP_1_1)
				.code(200).message("Synthetic").body(okhttp3.ResponseBody.create(null, body)).build()
		}.build()
		val state = JoinBlaketUiState().apply {
			wallet.value = "Synthetic Jars"
			session.value = JSONObject().put("session", true).put("maker_running", false)
			client.value = JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"), http)
			authorization.value = JoinBlaketAuthorization("fixture.jmdat", "synthetic-token")
		}
		compose.setContent { MaterialTheme(colorScheme = paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp)) { JoinBlaketPage(state) }
		} } }
		compose.onNodeWithText("Jars payment activity").performScrollTo().performClick()
		compose.waitUntil(10000) { compose.onAllNodesWithText("No saved Paperclip payments in this Jam wallet.").fetchSemanticsNodes().isNotEmpty() }
		val before = paths.size
		compose.runOnIdle { state.authorization.value = JoinBlaketAuthorization("fixture.jmdat", "replacement-token") }
		compose.waitForIdle()
		compose.onNodeWithText("Jars payments").assertDoesNotExist()
		assertEquals("Changing credentials must not implicitly reload payment history", before, paths.size)
	}
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
		try {
			compose.waitUntil(10000) { compose.onAllNodesWithText("Status unknown").fetchSemanticsNodes().isNotEmpty() }
		} catch (failure: ComposeTimeoutException) {
			// The runner's final screenshot is taken after later cases and cannot
			// explain this transition. Retain this synthetic page at the failure.
			runCatching { saveScreenshot("android-jars-history-timeout") }
			val routeCounts = synchronized(paths) { paths.groupingBy { it.substringAfterLast('/') }.eachCount() }
			throw AssertionError("Synthetic recovery did not appear; requests=$routeCounts; " +
				runCatching { compose.onRoot(useUnmergedTree = true).printToString().take(12000) }.getOrDefault("UI unavailable"), failure)
		}
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

	@Test fun bondFundingEntryKeepsRegisteredAddressAndDateFixed() {
		var calls = 0
		val http = okhttp3.OkHttpClient.Builder().addInterceptor { calls++; error("No funding requested") }.build()
		val state = JoinBlaketUiState().apply {
			wallet.value="fixture.jmdat"; client.value=JoinBlaketClient(JoinBlaketConnection("https://jam.example.invalid"),http)
			authorization.value=JoinBlaketAuthorization("fixture.jmdat","synthetic-token")
			session.value=JSONObject().put("session",true).put("maker_running",false).put("coinjoin_in_process",false).put("rescanning",false)
			jars.value=listOf("Apricot","Blueberry","Cherry","Date","Elderberry").mapIndexed { id,name ->
				JSONObject().put("id",id).put("name",name).put("total_sat",200000).put("confirmed_sat",200000).put("pending_sat",0).put("frozen_sat",0).put("bond_sat",0)
			}
			bondMonth.value="2099-12";bondAddress.value="bcrt1qsyntheticrecipient"
		}
		compose.setContent { MaterialTheme(colorScheme=paperclipColors(true)) { Surface {
			Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) { JoinBlaketPage(state) }
		} } }
		compose.onNodeWithText("Fidelity bond").performScrollTo().performClick()
		compose.onNodeWithText("Fund from Apricot").performScrollTo().performClick()
		compose.onNodeWithText("Review payment").performScrollTo().assertIsDisplayed()
		compose.onNodeWithText("XBT address").assertDoesNotExist()
		compose.onNodeWithTag("jars-send-coinjoin").assertDoesNotExist()
		compose.onNodeWithText("bcrt1qsyntheticrecipient").assertExists()
		capture("android-bond-funding-entry")
		compose.onNodeWithText("Close").performClick()
		compose.runOnIdle { assertEquals(0,calls) }
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
				"/api/v1/paperclip/market/100000" -> """{"amount_sat":100000,"fetched_at":$now,"book_updated_at":$now,"status":"fresh","maker_count":2,"median_fee_sat":"75.5","excluded_offer_count":0,"offers":${org.json.JSONArray((0 until 12).map { i -> JSONObject().put("id",i).put("maker","J5Synthetic$i").put("fee","100").put("relative",false).put("min_sat",27300).put("max_sat",1000000+i).put("fee_sat",100).put("mining_contribution_sat",0).put("bond_verified",true) })}}"""
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
		compose.onNodeWithText("Order book").performScrollTo().performClick()
		compose.onNodeWithText("Refresh order book").performScrollTo().performClick()
		compose.waitUntil(10000) { compose.onAllNodesWithText("Median maker fee: 75.5 sats",substring=true).fetchSemanticsNodes().isNotEmpty() }
		compose.onNodeWithText("Median maker fee: 75.5 sats",substring=true).performScrollTo().assertIsDisplayed()
		compose.onNodeWithText("J5Synthetic0").performScrollTo().assertIsDisplayed()
		compose.onAllNodesWithText("Bond verified")[0].assertExists()
		capture("android-maker-market")
		compose.onNodeWithText("Next").performScrollTo().performClick()
		compose.onNodeWithText("J5Synthetic10").performScrollTo().assertIsDisplayed()
		compose.onNodeWithText("J5Synthetic0").assertDoesNotExist()
		compose.onNodeWithText("Done").performClick()
		compose.onNodeWithText("Maker settings").performScrollTo().performClick()
		compose.onNodeWithText("Your fee: 0.005%").performScrollTo().assertIsDisplayed()
		compose.onNodeWithText("Done").performClick()
		compose.onNodeWithText("How earning works").performScrollTo().performClick()
		compose.onNodeWithText("JoinBlaket’s default takers require a fidelity bond.",substring=true).performScrollTo().assertIsDisplayed()
		assertEquals(listOf("/api/v1/session","/api/v1/paperclip/market/100000"),paths.toList())
	}

	@Test fun visibilityGuardRejectsCoveredFixtureAndPreservesEvidence() {
		compose.setContent { androidx.compose.material3.Text("Synthetic visibility fixture") }
		compose.onNodeWithText("Synthetic visibility fixture").assertIsDisplayed()
		val instrumentation = InstrumentationRegistry.getInstrumentation()
		instrumentation.targetContext.startActivity(Intent(Intent.ACTION_MAIN).apply {
			addCategory(Intent.CATEGORY_HOME)
			addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
		})
		compose.waitUntil(10_000) {
			val visible = instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString()
			visible != null && visible != instrumentation.targetContext.packageName
		}
		val captureName = "android-visibility-negative-control-${System.nanoTime()}"
		val failure = runCatching { capture(captureName) }.exceptionOrNull()
		assertTrue("Covered fixtures must fail the visibility gate", failure is AssertionError)
		assertTrue(failure?.cause is ComposeTimeoutException)
		assertTrue(failure?.message?.contains("expected_package") == true)
		instrumentation.targetContext.contentResolver.query(
			MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
			arrayOf(MediaStore.Images.Media.SIZE),
			"${MediaStore.Images.Media.DISPLAY_NAME} = ? AND ${MediaStore.Images.Media.IS_PENDING} = 0",
			arrayOf("$captureName-blocked.png"), null,
		).use { result ->
			assertTrue("Blocked fixture screenshot must survive app removal", result != null && result.moveToFirst() && result.getLong(0) > 0)
		}
	}

	private fun capture(name: String) {
		val instrumentation = InstrumentationRegistry.getInstrumentation()
		// A passing Compose assertion does not prove the page is visible: an
		// emulator system dialog can cover it without blocking semantics actions.
		try {
			compose.waitUntil(10_000) {
				instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString() == instrumentation.targetContext.packageName
			}
		} catch (failure: ComposeTimeoutException) {
			// Synthetic fixture screens only. Do not log arbitrary dialog text,
			// node data or credentials, and never hide the original failure.
			val root = instrumentation.uiAutomation.rootInActiveWindow
			val report = runCatching {
				val systemDialog = root?.packageName?.toString() == "android"
				val notResponding = systemDialog && listOf("isn't responding", "isn’t responding", "not responding")
					.any { root?.findAccessibilityNodeInfosByText(it)?.isNotEmpty() == true }
				val subject = if (!notResponding) "none" else
					listOf("System UI" to "system-ui", "Process system" to "system-process", "Pixel Launcher" to "launcher", "Quickstep" to "quickstep")
						.firstOrNull { root?.findAccessibilityNodeInfosByText(it.first)?.isNotEmpty() == true }?.second ?: "unknown"
				JSONObject().put("expected_package", instrumentation.targetContext.packageName)
					.put("active_package", root?.packageName?.toString() ?: JSONObject.NULL)
					.put("not_responding", notResponding).put("system_subject", subject)
					.put("windows", org.json.JSONArray().apply {
						instrumentation.uiAutomation.windows.forEach { window -> put(JSONObject()
							.put("type",window.type).put("active",window.isActive).put("focused",window.isFocused)
							.put("package",window.root?.packageName?.toString() ?: JSONObject.NULL)) }
					}).toString()
			}.getOrDefault("window metadata unavailable")
			runCatching { saveScreenshot("$name-blocked") }
			throw AssertionError("Cannot capture $name: $report", failure)
		}
		compose.waitForIdle()
		instrumentation.waitForIdleSync()
		saveScreenshot(name)
	}

	private fun saveScreenshot(name: String) {
		val instrumentation = InstrumentationRegistry.getInstrumentation()
		val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
		try {
			// Gradle uninstalls the test app. Publish fixture evidence to the same
			// test-only directory the emulator runner collects, so it survives.
			val resolver = instrumentation.targetContext.contentResolver
			val values = ContentValues().apply {
				put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
				put(MediaStore.Images.Media.MIME_TYPE, "image/png")
				put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/PaperclipPreview")
				put(MediaStore.Images.Media.IS_PENDING, 1)
			}
			val uri = checkNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
			checkNotNull(resolver.openOutputStream(uri)).use {
				check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
			}
			resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
		} finally {
			image.recycle()
		}
	}
}
