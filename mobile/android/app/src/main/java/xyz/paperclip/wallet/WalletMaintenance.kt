package xyz.paperclip.wallet

import android.app.KeyguardManager
import android.content.Context
import androidx.work.*
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeout

internal object WalletMaintenance {
	@Volatile var foreground = false

	fun schedule(context: Context, enabled: Boolean) {
		val manager = WorkManager.getInstance(context)
		if (!enabled) {
			manager.cancelUniqueWork("wallet-maintenance")
			return
		}
		val work =
			PeriodicWorkRequestBuilder<WalletMaintenanceWorker>(1, TimeUnit.HOURS)
				.setConstraints(
					Constraints.Builder()
						.setRequiredNetworkType(NetworkType.CONNECTED)
						.setRequiresBatteryNotLow(true)
						.build(),
				)
				.setInitialDelay(1, TimeUnit.HOURS)
				.build()
		manager.enqueueUniquePeriodicWork(
			"wallet-maintenance",
			ExistingPeriodicWorkPolicy.KEEP,
			work,
		)
	}
}

class WalletMaintenanceWorker(context: Context, parameters: WorkerParameters) :
	CoroutineWorker(context, parameters) {
	override suspend fun doWork(): Result {
		val context = applicationContext
		if (
			!context
				.getSharedPreferences("payment-options", Context.MODE_PRIVATE)
				.getBoolean("maintenance", false)
		)
			return Result.success()
		if (
			WalletMaintenance.foreground ||
				(context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager)
					.isDeviceLocked
		)
			return Result.success()
		val engine = WalletEngine.shared(context)
		return try {
			withTimeout(300000) {
				PaymentGate.run {
					if (WalletMaintenance.foreground) return@run
					val id = engine.activeID() ?: return@run
					if (engine.profiles().first { it.id == id }.kind != "hot") return@run
					try {
						engine.open()
						engine.connect(engine.connection())
						engine.call("sync_ark")
						engine.call("refresh")
						ExpiryReminders.update(context, id, engine.call("sync_ark"))
						val account = engine.call("overview_onchain").getString("account")
						PaymentAlerts(context)
							.observe(WalletActivity.parse(engine.call("activity")), id, account)
					} finally {
						engine.close()
					}
				}
			}
			Result.success()
		} catch (e: CancellationException) {
			engine.cancelSync()
			throw e
		} catch (_: Exception) {
			Result.retry()
		}
	}
}
