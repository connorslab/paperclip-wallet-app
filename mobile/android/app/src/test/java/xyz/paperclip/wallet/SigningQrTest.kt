package xyz.paperclip.wallet

import com.sparrowwallet.hummingbird.UR
import com.sparrowwallet.hummingbird.UREncoder
import org.junit.Assert.*
import org.junit.Test

class SigningQrTest {
	private fun fixtures(name: String) = org.json.JSONArray(javaClass.classLoader!!.getResource("$name.json")!!.readText())
	@Test fun sharedQrAcceptanceAndCompletedTransferIsOneShot() {
		val cases = fixtures("signing-qr-parity")
		for (i in 0 until cases.length()) {
			val item = cases.getJSONObject(i); val collector = SigningQrCollector()
			var result: ByteArray? = null
			val frames = item.getJSONArray("frames")
			val accepted = runCatching { for (j in 0 until frames.length()) collector.accept(frames.getString(j))?.let { result = it } }.isSuccess
			assertEquals(item.getString("name"), item.getBoolean("valid"), accepted)
			if (accepted) {
				assertArrayEquals(java.util.Base64.getDecoder().decode(item.getString("decoded")), result)
				assertNull(collector.accept("B\$HP010070736274FF"))
			}
		}
		val switched = SigningQrCollector(); assertNull(switched.accept("p1of2 public", true))
		assertThrows(IllegalArgumentException::class.java) { switched.accept("p2of2 account", false) }
		assertThrows(IllegalArgumentException::class.java) { SigningQr.binary("") }
	}
	@Test fun kruxAndSeedSignerWalletAndJarTransfers() {
		for (name in listOf("krux","seedsigner","krux-jam","seedsigner-jam")) {
			val rows = fixtures(name)
			for (i in 0 until rows.length()) {
				val row = rows.getJSONObject(i); val signed = java.util.Base64.getDecoder().decode(row.getString("signed"))
				val variants = mutableListOf(SigningQr.frames(signed))
				if (row.has("ur")) variants.add(row.getJSONArray("ur").let { a -> (0 until a.length()).map { a.getString(it) } })
				for (frames in variants) {
					val collector = SigningQrCollector(); var result: ByteArray? = null
					for (frame in frames.reversed()) collector.accept(frame)?.let { result = it }
					assertArrayEquals(name, signed, result); assertNull(collector.accept(frames[0]))
				}
			}
		}
	}
	@Test
	fun bbqrRoundTripOutOfOrderAndDuplicates() {
		val data = ByteArray(4097) { (it % 251).toByte() }
		val frames = SigningQr.frames(data)
		val collector = SigningQrCollector()
		assertNull(collector.accept(frames.last()))
		assertNull(collector.accept(frames.last()))
		var result: ByteArray? = null
		for (frame in frames.dropLast(1).reversed()) result = collector.accept(frame)
		assertArrayEquals(data, result)
	}

	@Test
	fun mixedQrFramesAreRejected() {
		val frames = SigningQr.frames(ByteArray(700) { 3 })
		val c = SigningQrCollector()
		c.accept(frames[0])
		assertThrows(IllegalArgumentException::class.java) { c.accept(frames[0].dropLast(1) + "Z") }
		assertThrows(IllegalArgumentException::class.java) { c.accept("p1of2 AAAA") }
	}

	@Test
	fun urFountainRoundTrip() {
		val data = ByteArray(2000) { (it % 251).toByte() }
		val encoder = UREncoder(UR.fromBytes("crypto-psbt", data), 100, 10, 0)
		val c = SigningQrCollector()
		var result: ByteArray? = null
		repeat(200) { if (result == null) result = c.accept(encoder.nextPart()) }
		assertArrayEquals(data, result)
	}

	@Test
	fun oversizedAndBadPaddingRejected() {
		assertThrows(IllegalArgumentException::class.java) {
			SigningQrCollector().accept("x".repeat(4097))
		}
		assertThrows(IllegalArgumentException::class.java) { SigningQr.decode32("AB") }
		assertThrows(IllegalArgumentException::class.java) {
			SigningQr.frames(ByteArray(SigningQr.MAX + 1))
		}
	}
}
