package xyz.paperclip.wallet

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext

@Composable
internal fun PaymentSettings() {
	val context = LocalContext.current
	val prefs = remember { context.getSharedPreferences("payment-options", Context.MODE_PRIVATE) }
	var alerts by remember { mutableStateOf(prefs.getBoolean("alerts", false)) }
	var expiry by remember { mutableStateOf(prefs.getBoolean("expiry", false)) }
	var maintenance by remember { mutableStateOf(prefs.getBoolean("maintenance", false)) }
	var message by remember { mutableStateOf("") }
	val permission =
		rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
			message =
				if (granted) "Payment alerts enabled"
				else "Allow notifications in Android Settings to receive alerts"
		}
	Text("Alerts and maintenance", style = MaterialTheme.typography.titleLarge)
	Row {
		Switch(
			alerts,
			{ enabled ->
				alerts = enabled
				prefs.edit().putBoolean("alerts", enabled).apply()
				PaymentAlerts(context).reset()
				if (enabled && Build.VERSION.SDK_INT >= 33)
					permission.launch(Manifest.permission.POST_NOTIFICATIONS)
			},
		)
		Text("Payment status notifications")
	}
	Text(
		"Alerts use wallet refreshes. Amounts, addresses and wallet names stay out of notifications. Existing history is not announced when you enable alerts. Connected Lightning nodes have separate status monitoring.",
	)
	Row {
		Switch(
			expiry,
			{ enabled ->
				expiry = enabled
				prefs.edit().putBoolean("expiry", enabled).apply()
				if (!enabled)
					androidx.work.WorkManager.getInstance(context).cancelAllWorkByTag("expiry")
				if (enabled && Build.VERSION.SDK_INT >= 33)
					permission.launch(Manifest.permission.POST_NOTIFICATIONS)
			},
		)
		Text("Ark expiry reminders")
	}
	Text(
		"Refresh your wallet after enabling reminders. Expiry is block-based; reminder times are estimates and Android may delay them. Open Paperclip regularly even if no alert arrives.",
	)
	Row {
		Switch(
			maintenance,
			{ enabled ->
				maintenance = enabled
				prefs.edit().putBoolean("maintenance", enabled).apply()
				WalletMaintenance.schedule(context, enabled)
			},
		)
		Text("Automatic Ark maintenance")
	}
	Text(
		"Check the selected mobile wallet and refresh eligible Ark funds while open. Android may also run periodic checks while the device is unlocked, connected and not low on battery. Background timing is not guaranteed. Open each wallet regularly and keep a current encrypted backup.",
	)
	if (message.isNotEmpty()) Text(message)
	TextButton(
		onClick = {
			context.startActivity(
				Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
					.putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName),
			)
		},
	) {
		Text("Android notification settings")
	}
}

@Composable
internal fun HelpPage(buy: Boolean = false) {
	val context = LocalContext.current
	var error by remember { mutableStateOf("") }
	fun open(url: String) {
		runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
			.onFailure { error = "No app could open this link" }
	}
	Text(if (buy) "Buy XBT" else "Help and support", style = MaterialTheme.typography.titleLarge)
	if (buy) {
		Text(
			"Buy XBT externally, then withdraw to your Paperclip on-chain receive address. Exchange terms and availability are controlled by each provider.",
		)
		TextButton(onClick = { open("https://safetrade.com/exchange/XBT-USDT?type=pro") }) {
			Text("SafeTrade · XBT/USDT")
		}
		TextButton(onClick = { open("https://neoxa.exchange/trade/BTCB2_USDC") }) {
			Text("NeoxEx · BTCB2/USDC")
		}
		TextButton(onClick = { open("https://neoxa.exchange/trade/BTCB2_BTC") }) {
			Text("NeoxEx · BTCB2/BTC")
		}
		TextButton(onClick = { open("https://neoxa.exchange/register?ref=NEXE5E25284") }) {
			Text("Create NeoxEx account · referral link")
		}
	} else {
		Text(
			"Contact Paperclip Holdings LLC. Include your app version, Android version and what happened. Never share seed words, private keys, backup recovery keys or node credentials.",
		)
		TextButton(
			onClick = {
				open("mailto:contact@paperclippool.xyz?subject=Paperclip%20Wallet%20Support")
			},
		) {
			Text("Email Paperclip")
		}
		TextButton(
			onClick = {
				open(
					"https://github.com/connorslab/paperclip-wallet-app/blob/feature/ios-wallet/mobile/docs/support.md",
				)
			},
		) {
			Text("Connection, payment and recovery help")
		}
		TextButton(
			onClick = {
				open(
					"https://github.com/connorslab/paperclip-wallet-app/blob/feature/ios-wallet/mobile/docs/privacy.md",
				)
			},
		) {
			Text("Privacy policy")
		}
		Text("Paperclip Android ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
	}
	if (error.isNotBlank()) Text(error)
}

@Composable
internal fun WalletSecurity() {
	val context = LocalContext.current
	val activity = LocalActivity.current as? MainActivity
	var enabled by remember {
		mutableStateOf(
			context
				.getSharedPreferences("security", Context.MODE_PRIVATE)
				.getBoolean("walletLock", true),
		)
	}
	Text("Wallet security", style = MaterialTheme.typography.titleLarge)
	Row {
		Text("Require device authentication", Modifier.weight(1f))
		Switch(enabled, { next -> activity?.setWalletLock(next) { enabled = next } })
	}
	Text(
		"Wallet data is encrypted with an Android Keystore key and excluded from system backups. Disabling this prompt lets anyone using your unlocked device open Paperclip. Sensitive actions still require device authentication.",
	)
	Text(
		"On-chain signatures use unified sighash (0x21). Message ownership proofs use BIP322-simple and cannot spend funds.",
	)
}

@Composable
internal fun OpenSourceNotices() {
	val context = LocalContext.current
	var notices by remember { mutableStateOf("") }
	LaunchedEffect(Unit) {
		notices =
			kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
				context.assets.list("licenses").orEmpty().sorted().joinToString("\n\n") { name ->
					name +
						"\n\n" +
						context.assets.open("licenses/$name").bufferedReader().use { it.readText() }
				}
			}
	}
	Text("Open-source notices", style = MaterialTheme.typography.titleLarge)
	androidx.compose.foundation.text.selection.SelectionContainer {
		Text(notices, style = MaterialTheme.typography.bodySmall)
	}
}
