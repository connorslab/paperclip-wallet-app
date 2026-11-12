package xyz.paperclip.wallet

import android.content.Context
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import java.math.BigDecimal
import java.text.NumberFormat
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject

enum class BitcoinUnit(val title: String) {
	SATS("sats"),
	XBT("XBT");

	fun parse(text: String): Long? = runCatching {
		val value = text.trim().replace(',', '.')
		require(
			value.matches(if (this == SATS) Regex("[0-9]+") else Regex("[0-9]+(?:\\.[0-9]{0,8})?")),
		)
		val result =
			BigDecimal(value)
				.multiply(if (this == SATS) BigDecimal.ONE else BigDecimal(100000000))
				.longValueExact()
		require(result in 0..2100000000000000L)
		result
	}
		.getOrNull()

	fun input(sats: Long): String =
		if (this == SATS) sats.toString()
		else BigDecimal.valueOf(sats, 8).stripTrailingZeros().toPlainString()

	fun backendAmount(text: String): String =
		if (text.isBlank()) "" else parse(text)?.toString() ?: "invalid"

	fun displayMsat(msat: Long): String =
		"${BigDecimal.valueOf(msat,if(this==SATS)3 else 11).stripTrailingZeros().toPlainString()} $title"

	fun display(sats: Long): String =
		if (this == SATS) "${NumberFormat.getIntegerInstance().format(sats)} sats"
		else "${BigDecimal.valueOf(sats,8).stripTrailingZeros().toPlainString()} XBT"
}

internal val LocalBitcoinUnit = staticCompositionLocalOf { BitcoinUnit.SATS }

internal data class PublicQuote(val usd: Double, val updated: Long) {
	fun valid(now: Long) =
		usd.isFinite() && usd > 0 && updated <= now + 300000 && now - updated < 86400000

	companion object {
		fun parse(json: String, now: Long): PublicQuote {
			val j = JSONObject(json)
			return PublicQuote(j.getDouble("price"), j.getLong("updated")).also {
				require(it.valid(now))
			}
		}
	}
}

internal object XbtPrice {
	private val mutex = Mutex()
	private val client =
		OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).followRedirects(false).build()
	val quote = mutableStateOf<PublicQuote?>(null)
	private var next = 0L
	private var loaded = false

	suspend fun refresh(context: Context, force: Boolean = false) = mutex.withLock {
		val now = System.currentTimeMillis()
		val prefs = context.getSharedPreferences("public-price", Context.MODE_PRIVATE)
		if (!loaded) {
			loaded = true
			quote.value =
				runCatching { PublicQuote.parse(prefs.getString("quote", null) ?: "", now) }
					.getOrNull()
		}
		if (!force && now < next) return@withLock
		try {
			val json =
				withContext(Dispatchers.IO) {
					client
						.newCall(Request.Builder().url("https://xbt.live/api/widget").build())
						.execute()
						.use { response ->
							require(response.code == 200)
							val source = checkNotNull(response.body).source()
							require(!source.request(65537))
							source.readUtf8()
						}
				}
			val value = PublicQuote.parse(json, System.currentTimeMillis())
			quote.value = value
			prefs.edit().putString("quote", json).apply()
			next = now + 300000
		} catch (e: kotlinx.coroutines.CancellationException) {
			throw e
		} catch (_: Exception) {
			next = now + 30000
		}
	}
}

@Composable
internal fun UsdValue(sats: Long?, mainnet: Boolean, hidden: Boolean = false) {
	if (!mainnet) return
	val context = LocalContext.current.applicationContext
	val owner = LocalLifecycleOwner.current
	var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
	var retry by remember { mutableIntStateOf(0) }
	LaunchedEffect(owner, retry) {
		owner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
			var force = retry > 0
			while (true) {
				XbtPrice.refresh(context, force)
				force = false
				now = System.currentTimeMillis()
				delay(30000)
			}
		}
	}
	val quote = XbtPrice.quote.value
	if (hidden) Text("•••• USD")
	else if (sats == null) Text("USD estimate pending balance")
	else if (quote != null && quote.valid(now)) {
		val value = sats.toDouble() / 100000000 * quote.usd
		Text(
			"≈ ${NumberFormat.getCurrencyInstance(Locale.US).format(value)} USD${if(now-quote.updated>900000)" · stale rate" else ""}",
		)
	} else TextButton(onClick = { retry++ }) { Text("USD unavailable · retry") }
}
