package xyz.paperclip.wallet

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

class MainActivity : FragmentActivity() {
	private val model: WalletModel by viewModels()
	private val lightning: LightningModel by viewModels()
	private val bridge: BridgeModel by viewModels()
	private val coinjoin: CoinjoinModel by viewModels()
	private val unlocked = mutableStateOf(false)
	private val authError = mutableStateOf("")
	private var restoreKey = ""
	private val export =
		registerForActivityResult(
			ActivityResultContracts.CreateDocument("application/octet-stream"),
		) { uri ->
			if (uri != null) model.saveBackupFile(uri)
		}
	private val restore =
		registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
			val key = restoreKey
			restoreKey = ""
			if (uri != null) model.restoreBackupFile(uri, key)
		}

	fun exportBackup() {
		export.launch("paperclip-wallet.backup")
	}

	fun restoreBackup(key: String) {
		restoreKey = key
		restore.launch(arrayOf("*/*"))
	}

	private val screenshots
		get() = BuildConfig.DEBUG && intent.getBooleanExtra("regtestScreenshots", false)

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
		setContent {
			PaperclipApp(
				model,
				unlocked.value,
				authError.value,
				::unlock,
				lightning,
				bridge,
				coinjoin,
			)
		}
		if (screenshots)
			lifecycleScope.launch {
				val network = WalletEngine.shared(applicationContext).network()
				if (network == null || network == "xbt-regtest") {
					window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
					unlocked.value = true
					model.load(screenshots = true)
				} else {
					authError.value =
						"Screenshot mode cannot open a mainnet wallet. Restart normally to unlock."
				}
			}
	}

	override fun onStart() {
		super.onStart()
		WalletMaintenance.foreground = true
		if (
			!screenshots &&
				!unlocked.value &&
				!getSharedPreferences("security", MODE_PRIVATE).getBoolean("walletLock", true)
		)
			openUnlocked()
	}

	private fun openUnlocked() {
		unlocked.value = true
		authError.value = ""
		model.load()
		lightning.load()
		bridge.load()
	}

	fun setWalletLock(enabled: Boolean, changed: () -> Unit) {
		authenticateAction("Change wallet authentication") {
			getSharedPreferences("security", MODE_PRIVATE)
				.edit()
				.putBoolean("walletLock", enabled)
				.apply()
			changed()
		}
	}

	fun authenticateAction(reason: String, action: () -> Unit) {
		if (!unlocked.value || screenshots) return
		val prompt =
			BiometricPrompt(
				this,
				ContextCompat.getMainExecutor(this),
				object : BiometricPrompt.AuthenticationCallback() {
					override fun onAuthenticationSucceeded(
						result: BiometricPrompt.AuthenticationResult,
					) {
						if (unlocked.value) action()
					}
				},
			)
		prompt.authenticate(
			BiometricPrompt.PromptInfo.Builder()
				.setTitle(reason)
				.setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)
				.build(),
		)
	}

	private fun unlock() {
		if (screenshots) return
		val prompt =
			BiometricPrompt(
				this,
				ContextCompat.getMainExecutor(this),
				object : BiometricPrompt.AuthenticationCallback() {
					override fun onAuthenticationSucceeded(
						result: BiometricPrompt.AuthenticationResult,
					) {
						openUnlocked()
					}

					override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
						authError.value = errString.toString()
					}
				},
			)
		prompt.authenticate(
			BiometricPrompt.PromptInfo.Builder()
				.setTitle("Unlock Paperclip")
				.setSubtitle("Use your fingerprint or device screen lock")
				.setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)
				.build(),
		)
	}

	override fun onStop() {
		super.onStop()
		WalletMaintenance.foreground = false
		coinjoin.stop()
		if (!screenshots) {
			unlocked.value = false
			model.lock()
			lightning.lock()
			bridge.lock()
		}
	}
}
