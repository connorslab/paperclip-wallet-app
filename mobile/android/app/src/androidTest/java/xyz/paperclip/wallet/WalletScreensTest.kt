package xyz.paperclip.wallet

import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.provider.MediaStore
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test

/** Runs against the actual JNI engine, without any mock wallet balances. */
class WalletScreensTest {
	@get:Rule val compose = createEmptyComposeRule()

	private fun capture(name: String) {
		compose.waitForIdle()
		// Allow the Android render thread to present the settled Compose frame.
		InstrumentationRegistry.getInstrumentation().waitForIdleSync()
		android.os.SystemClock.sleep(600)
		val instrumentation = InstrumentationRegistry.getInstrumentation()
		// Accessibility attaches asynchronously on the first capture. Wait for a
		// real wallet window; never accept a system error dialog as a UI preview.
		var observedPackage: String? = null
		try {
			compose.waitUntil(10_000) {
				observedPackage = instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString()
				observedPackage == instrumentation.targetContext.packageName
			}
		} catch (error: ComposeTimeoutException) {
			// Classify known system dialogs without logging their text, wallet
			// content or recovery words. Keep the original assertion.
			val root = instrumentation.uiAutomation.rootInActiveWindow
			val dialog = if (root == null || root.packageName?.toString() != "android") "none" else when {
				listOf("isn't responding", "isn’t responding", "not responding").any { root.findAccessibilityNodeInfosByText(it).isNotEmpty() } -> "not-responding"
				listOf("keeps stopping", "has stopped").any { root.findAccessibilityNodeInfosByText(it).isNotEmpty() } -> "crash"
				root.findAccessibilityNodeInfosByText("older version").isNotEmpty() -> "compatibility"
				else -> "unclassified-system-dialog"
			}
			val exits = if (android.os.Build.VERSION.SDK_INT >= 30) runCatching {
				instrumentation.targetContext.getSystemService(android.app.ActivityManager::class.java)
					.getHistoricalProcessExitReasons(instrumentation.targetContext.packageName, 0, 3)
					.filter { it.processName == instrumentation.targetContext.packageName }.map { it.reason }
			}.getOrDefault(emptyList()) else emptyList()
			val label = instrumentation.targetContext.applicationInfo.loadLabel(instrumentation.targetContext.packageManager).toString()
			val mentionsApp = root?.findAccessibilityNodeInfosByText(label)?.isNotEmpty() == true
			// Fixed categories only: never include arbitrary dialog titles/text.
			val systemSubject = if (dialog != "not-responding" || mentionsApp) "none" else
				listOf("System UI" to "system-ui", "Process system" to "system-process",
					"Pixel Launcher" to "launcher", "Google Play services" to "play-services")
					.firstOrNull { root?.findAccessibilityNodeInfosByText(it.first)?.isNotEmpty() == true }?.second ?: "unknown"
			// Only code symbols and line numbers, never message text, arguments,
			// local values or the system ANR trace (which can include private data).
			val mainMethods = android.os.Looper.getMainLooper().thread.stackTrace.take(16)
				.map { "${it.className}.${it.methodName}:${it.lineNumber}" }
			throw AssertionError("Cannot capture $name: active accessibility package was ${observedPackage ?: "unavailable"}; expected ${instrumentation.targetContext.packageName}; dialog=$dialog; mentionsApp=$mentionsApp; systemSubject=$systemSubject; recent exit reason codes=$exits; main methods=$mainMethods", error)
		}
		val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
		// Public test images survive the test runner's automatic APK uninstall.
		val resolver = instrumentation.targetContext.contentResolver
		val values =
			ContentValues().apply {
				put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
				put(MediaStore.Images.Media.MIME_TYPE, "image/png")
				put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/PaperclipPreview")
				put(MediaStore.Images.Media.IS_PENDING, 1)
			}
		val uri =
			checkNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values))
		checkNotNull(resolver.openOutputStream(uri)).use {
			image.compress(Bitmap.CompressFormat.PNG, 100, it)
		}
		resolver.update(
			uri,
			ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
			null,
			null,
		)
		image.recycle()
	}

	private fun waitFor(text: String) {
		compose.waitUntil(30_000) {
			compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
		}
	}

	private fun click(text: String) {
		waitFor(text)
		compose.onNodeWithText(text).performScrollTo().performClick()
	}

	private fun back() {
		// Restored content can appear while the authenticated wallet reloads.
		// A disabled button is not an accepted navigation action.
		compose.waitUntil(30_000) {
			compose.onAllNodes(hasContentDescription("Back") and isEnabled())
				.fetchSemanticsNodes().isNotEmpty()
		}
		compose.onNodeWithContentDescription("Back").assertIsEnabled().performClick()
	}

	@Test
	fun nativeWalletAndNavigation() {
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		check(kotlinx.coroutines.runBlocking { WalletEngine.shared(context).profiles().isEmpty() }) {
			"Onboarding screenshots require an empty QA app. Preserve existing wallets and use a fresh test device."
		}
		val intent = Intent(context, MainActivity::class.java).putExtra("regtestScreenshots", true)
		ActivityScenario.launch<MainActivity>(intent).use { scenario ->
			waitFor("Create a test wallet")
			capture("01-onboarding")
			click("Create a test wallet")
			click("Generate 24 words")
			waitFor("I wrote down every word")
			val words =
				(0 until 24).map { index ->
					val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
					compose
						.onNodeWithTag("seed-word-$index", useUnmergedTree = true)
						.performSemanticsAction(
							androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult,
						) {
							it(layouts)
						}
					// Paragraph dimensions are fractional pixels; measured bounds are integers.
					// Allow only that rounding, not wrapped or visibly clipped recovery words.
					check(
						layouts.isNotEmpty() &&
							layouts.all {
								it.lineCount == 1 &&
									it.getLineLeft(0) >= -1f &&
									it.getLineRight(0) <= it.size.width + 1f &&
									it.multiParagraph.height <= it.size.height + 1f
							},
					) {
						"Word ${index + 1} layout: ${layouts.map { "lines=${it.lineCount}, right=${it.getLineRight(0)}, paragraphHeight=${it.multiParagraph.height}, size=${it.size}" }}"
					}
					compose
						.onNodeWithTag("seed-word-$index", useUnmergedTree = true)
						.fetchSemanticsNode()
						.config[androidx.compose.ui.semantics.SemanticsProperties.Text]
						.first()
						.text
				}
			click("I wrote down every word")
			compose.onNodeWithText("Verify and create wallet").assertIsNotEnabled()
			compose.onNodeWithTag("seed-confirmation").performTextInput("wrong words")
			compose.onNodeWithText("Verify and create wallet").assertIsNotEnabled()
			compose
				.onNodeWithTag("seed-confirmation")
				.performTextReplacement(words.joinToString(" "))
			click("Verify and create wallet")
			waitFor("Total balance")
			compose.onNodeWithTag("wallet-switcher").performClick()
			waitFor("Add a wallet")
			compose.onAllNodes(hasContentDescription("Manage ", substring = true)).onFirst().performClick()
			click("Rename")
			compose.onNode(hasText("Wallet name") and hasAnyAncestor(isDialog())).performTextReplacement("Everyday wallet")
			compose.onNodeWithText("Save").performClick()
			compose.waitUntil(10_000) { compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty() }
			waitFor("Everyday wallet")
			back()
			capture("02-wallet")
			click("Send")
			waitFor("Send XBT")
			capture("03-send")
			back()
			click("Receive")
			click("Create address")
			compose.waitUntil(30_000) {
				compose
					.onAllNodesWithContentDescription("Receive QR code")
					.fetchSemanticsNodes()
					.isNotEmpty()
			}
			capture("04-receive")
			click("Copy")
			waitFor("Copied")
			click("Create another request")
			click("Ark")
			compose.onNodeWithContentDescription("Receive QR code").assertDoesNotExist()
			compose.onNodeWithText("Create address").assertIsNotEnabled()
			back()
			compose.onNodeWithTag("tab-Lightning").performClick()
			waitFor("Lightning through Ark")
			capture("05-lightning")
			click("Lightning through Ark")
			click("Receive a Lightning payment")
			waitFor("Create invoice")
			compose.onNodeWithText("Amount in sats").assertExists()
			compose.onNodeWithText("Create invoice").assertIsNotEnabled()
			capture("05-lightning-receive")
			back()
			compose.onNodeWithTag("tab-Jars").performClick()
			waitFor("JoinBlaket")
			click("Connect to a separate Jam server")
			compose.onNodeWithText("HTTPS or onion address").performTextInput("https://jam.example.test")
			compose.onNodeWithTag("tab-Lightning").performClick()
			compose.onNodeWithTag("tab-Jars").performClick()
			click("Connect to a separate Jam server")
			compose.onNodeWithText("https://jam.example.test").assertExists()
			compose.onNodeWithText("Previous Kilojoin funds and round recovery").assertDoesNotExist()
			capture("05-jars")
			compose.onNodeWithTag("tab-Activity").performClick()
			waitFor("No activity loaded")
			capture("06-activity")
			compose.onNodeWithTag("tab-Settings").performClick()
			waitFor("Your wallet")
			capture("07-settings-dark")
			click("Wallet tools")
			click("Experimental")
			click("Kilojoin recovery")
			waitFor("Previous CoinJoin")
			compose.onNodeWithText("Create pool").assertDoesNotExist()
			compose.onNodeWithText("New receive address").assertDoesNotExist()
			capture("11-coinjoin")
			compose.onNodeWithTag("tab-Settings").assertIsSelected()
			scenario.recreate()
			waitFor("Previous CoinJoin")
			compose.onNodeWithTag("tab-Settings").assertIsSelected()
			back()
			waitFor("Experimental")
			back()
			waitFor("Wallet tools")
			back()
			waitFor("Your wallet")
			click("Your wallets")
			waitFor("Add a wallet")
			capture("12-wallets")
			click("QR Signer")
			waitFor("Public descriptor or extended public key")
			compose.onNodeWithText("12 or 24 recovery words").assertDoesNotExist()
			compose.onNodeWithText("legacy").performScrollTo().assertIsDisplayed()
			capture("12-qr-wallet")
			back()
			click("Preferences")
			click("Alerts and maintenance")
			waitFor("Payment status notifications")
			capture("13-alerts")
			back()
			back()
			click("Connections")
			waitFor("Save and connect")
			capture("08-connections")
			compose
				.onNodeWithText("Chain endpoint")
				.performTextReplacement("ssl://example.invalid:50002")
			compose.onNodeWithText("Unsaved changes").assertExists()
			compose.onNodeWithTag("tab-Wallet").performClick()
			compose.onNodeWithTag("tab-Wallet").assertIsSelected()
			compose.onNodeWithTag("tab-Settings").performClick()
			waitFor("Save and connect")
			compose.onNodeWithText("Unsaved changes").assertExists()
			compose.onNodeWithTag("tab-Settings").assertIsSelected()
			back()
			click("Preferences")
			click("Light")
			back()
			compose.onNodeWithText("Your wallet").performScrollTo()
			capture("09-settings-light")
			scenario.onActivity { activity ->
				check(
					androidx.core.view.WindowCompat.getInsetsController(
							activity.window,
							activity.window.decorView,
						)
						.isAppearanceLightStatusBars,
				) {
					"Light appearance needs dark system status icons"
				}
			}
			compose.onNodeWithTag("tab-Wallet").performClick()
			capture("10-wallet-light")
		}
	}
}
