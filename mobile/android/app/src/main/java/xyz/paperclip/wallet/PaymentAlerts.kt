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
import org.json.JSONObject

internal class PaymentAlerts(private val context: Context) {
	private val vault = SecureStore(context)
	private val prefs = context.getSharedPreferences("payment-options", Context.MODE_PRIVATE)

	fun observe(items: List<WalletActivity>, wallet: String, account: String) {
		if (!prefs.getBoolean("alerts", false)) return
		val bytes = vault.read("payment-alert-state")
		val all =
			if (bytes == null) JSONObject()
			else
				try {
					JSONObject(String(bytes))
				} finally {
					bytes.fill(0)
				}
		val changed = mutableListOf<WalletActivity>()
		for ((scope, rows) in
			listOf(
				"$wallet:ark" to items.filter { it.ark },
				"$wallet:$account" to items.filter { !it.ark },
			)) {
			val baseline = ActivityBaseline(all.optJSONObject(scope) ?: JSONObject())
			changed += baseline.changes(rows, System.currentTimeMillis())
			all.put(scope, baseline.json())
		}
		val data = all.toString().toByteArray()
		try {
			vault.write("payment-alert-state", data)
		} finally {
			data.fill(0)
		}
		if (
			Build.VERSION.SDK_INT >= 33 &&
				ContextCompat.checkSelfPermission(
					context,
					Manifest.permission.POST_NOTIFICATIONS,
				) != PackageManager.PERMISSION_GRANTED
		)
			return
		val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
		manager.createNotificationChannel(
			NotificationChannel(
					"payments",
					"Payment updates",
					NotificationManager.IMPORTANCE_DEFAULT,
				)
				.apply { lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE },
		)
		val intent =
			PendingIntent.getActivity(
				context,
				0,
				Intent(context, MainActivity::class.java),
				PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
			)
		for (item in changed.take(5)) {
			val status =
				when (item.status) {
					"successful",
					"completed",
					"confirmed",
					"paid",
					"settled" -> "Confirmed"
					"failed",
					"not_sent" -> "Failed"
					else -> "Updated"
				}
			val notification =
				NotificationCompat.Builder(context, "payments")
					.setSmallIcon(android.R.drawable.stat_notify_sync)
					.setContentTitle(
						if (item.amount > 0) "Incoming payment update"
						else "Outgoing payment update",
					)
					.setContentText("Status: $status. Open Paperclip to view details.")
					.setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
					.setContentIntent(intent)
					.setAutoCancel(true)
					.build()
			manager.notify("payments:$wallet", (item.id + item.status).hashCode(), notification)
		}
	}

	fun forget(wallet: String) {
		val bytes = vault.read("payment-alert-state")
		if (bytes != null) {
			val all =
				try {
					JSONObject(String(bytes))
				} finally {
					bytes.fill(0)
				}
			all.keys()
				.asSequence()
				.filter { it.startsWith("$wallet:") }
				.toList()
				.forEach(all::remove)
			val data = all.toString().toByteArray()
			try {
				vault.write("payment-alert-state", data)
			} finally {
				data.fill(0)
			}
		}
		val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
		manager.activeNotifications
			.filter { it.tag == "payments:$wallet" }
			.forEach { manager.cancel(it.tag, it.id) }
	}

	fun reset() {
		vault.delete("payment-alert-state")
	}
}
