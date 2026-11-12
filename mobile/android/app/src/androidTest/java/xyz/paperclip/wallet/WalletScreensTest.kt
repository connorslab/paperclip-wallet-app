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
		compose.waitUntil(10_000) {
			instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString() ==
				instrumentation.targetContext.packageName
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
		compose.onNodeWithText(text).performScrollTo().performClick()
	}

	@Test
	fun nativeWalletAndNavigation() {
		val context = InstrumentationRegistry.getInstrumentation().targetContext
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
			waitFor("Your Keys. Your Bitcoin.")
			capture("02-wallet")
			click("Send")
			waitFor("Send XBT")
			capture("03-send")
			compose.onNodeWithContentDescription("Back").performClick()
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
			click("Ark")
			compose.onNodeWithContentDescription("Receive QR code").assertDoesNotExist()
			compose.onNodeWithText("Create address").assertIsNotEnabled()
			compose.onNodeWithContentDescription("Back").performClick()
			compose.onNodeWithTag("tab-Lightning").performClick()
			waitFor("Lightning through Ark")
			capture("05-lightning")
			click("Receive a Lightning payment")
			waitFor("Create invoice")
			compose.onNodeWithText("Amount in sats").assertExists()
			compose.onNodeWithText("Create invoice").assertIsNotEnabled()
			capture("05-lightning-receive")
			compose.onNodeWithContentDescription("Back").performClick()
			compose.onNodeWithTag("tab-Activity").performClick()
			waitFor("No activity loaded")
			capture("06-activity")
			compose.onNodeWithTag("tab-Settings").performClick()
			waitFor("Your wallet")
			capture("07-settings-dark")
			click("Coinjoin")
			waitFor("Experimental Coinjoin")
			capture("11-coinjoin")
			compose.onNodeWithContentDescription("Back").performClick()
			click("Wallets")
			waitFor("Add or rename a wallet")
			capture("12-wallets")
			compose.onNodeWithContentDescription("Back").performClick()
			click("Alerts and maintenance")
			waitFor("Payment status notifications")
			capture("13-alerts")
			compose.onNodeWithContentDescription("Back").performClick()
			click("Connection settings")
			waitFor("Save and connect")
			capture("08-connections")
			compose
				.onNodeWithText("Chain endpoint")
				.performTextReplacement("ssl://example.invalid:50002")
			compose.onNodeWithText("Unsaved changes").assertExists()
			compose.onNodeWithContentDescription("Back").performClick()
			click("Light")
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
