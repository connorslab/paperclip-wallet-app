package xyz.paperclip.wallet

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.*
import java.util.concurrent.TimeUnit
import org.json.JSONObject

internal data class ExpiryNotice(val id: String, val delaySeconds: Long)

/** Matches iOS's 600-second estimate; block height remains authoritative. */
internal object ExpiryPolicy {
	fun plan(tip: Long, expiry: Long?): List<ExpiryNotice> {
		if (tip < 0 || expiry == null) return emptyList()
		if (expiry <= tip) return listOf(ExpiryNotice("recovery", 5))
		val remaining = expiry - tip
		val notices = mutableListOf<ExpiryNotice>()
		for (window in listOf(432L, 144L, 72L)) {
			if (remaining <= window) {
				if (notices.none { it.id == "now" }) notices += ExpiryNotice("now", 5)
			} else
				notices +=
					ExpiryNotice(window.toString(), Math.multiplyExact(remaining - window, 600))
		}
		notices += ExpiryNotice("check", 6 * 3600)
		return notices
	}

	fun body(id: String) =
		when (id) {
			"recovery" ->
				"An Ark expiry height has been reached. Open Paperclip to check recovery options."
			"check" ->
				"Open Paperclip to update your Ark expiry check. Background refresh is not guaranteed."
			"now" ->
				"Ark funds may need attention. Open Paperclip to check expiry and refresh eligible funds. Timing is estimated."
			else ->
				"Check your Ark funds. Open Paperclip to refresh eligible funds before expiry. Timing is estimated."
		}
}

internal object ExpiryReminders {
	private val kinds = listOf("recovery", "now", "check", "432", "144", "72")

	fun update(context: Context, wallet: String, snapshot: JSONObject) {
		if (
			!context
				.getSharedPreferences("payment-options", Context.MODE_PRIVATE)
				.getBoolean("expiry", false)
		)
			return
		val vtxos = snapshot.getJSONArray("vtxos")
		val expiry =
			(0 until vtxos.length())
				.map { vtxos.getJSONObject(it).getLong("expiryHeight") }
				.minOrNull()
		val planned = ExpiryPolicy.plan(snapshot.getLong("tip"), expiry)
		val manager = WorkManager.getInstance(context)
		for (notice in planned) {
			val work =
				OneTimeWorkRequestBuilder<ExpiryReminderWorker>()
					.setInputData(workDataOf("wallet" to wallet, "notice" to notice.id))
					.setInitialDelay(notice.delaySeconds, TimeUnit.SECONDS)
					.addTag("expiry")
					.addTag("expiry:$wallet")
					.build()
			manager.enqueueUniqueWork(
				"expiry:$wallet:${notice.id}",
				ExistingWorkPolicy.REPLACE,
				work,
			)
		}
		for (kind in kinds.filter { kind -> planned.none { it.id == kind } }) manager
			.cancelUniqueWork("expiry:$wallet:$kind")
	}

	fun forget(context: Context, wallet: String) {
		WorkManager.getInstance(context).cancelAllWorkByTag("expiry:$wallet")
		val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
		for (kind in kinds) manager.cancel("expiry:$wallet", kind.hashCode())
	}
}

class ExpiryReminderWorker(context: Context, parameters: WorkerParameters) :
	Worker(context, parameters) {
	override fun doWork(): Result {
		val context = applicationContext
		if (
			!context
				.getSharedPreferences("payment-options", Context.MODE_PRIVATE)
				.getBoolean("expiry", false)
		)
			return Result.success()
		if (
			Build.VERSION.SDK_INT >= 33 &&
				ContextCompat.checkSelfPermission(
					context,
					Manifest.permission.POST_NOTIFICATIONS,
				) != PackageManager.PERMISSION_GRANTED
		)
			return Result.success()
		val wallet = inputData.getString("wallet") ?: return Result.failure()
		val kind = inputData.getString("notice") ?: return Result.failure()
		val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
		manager.createNotificationChannel(
			NotificationChannel(
				"expiry",
				"Ark expiry reminders",
				NotificationManager.IMPORTANCE_DEFAULT,
			),
		)
		val intent =
			PendingIntent.getActivity(
				context,
				0,
				Intent(context, MainActivity::class.java),
				PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
			)
		val notification =
			NotificationCompat.Builder(context, "expiry")
				.setSmallIcon(android.R.drawable.stat_notify_sync)
				.setContentTitle("Paperclip wallet check")
				.setContentText(ExpiryPolicy.body(kind))
				.setStyle(NotificationCompat.BigTextStyle().bigText(ExpiryPolicy.body(kind)))
				.setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
				.setContentIntent(intent)
				.setAutoCancel(true)
				.build()
		manager.notify("expiry:$wallet", kind.hashCode(), notification)
		return Result.success()
	}
}
