package xyz.paperclip.wallet

import com.sparrowwallet.hummingbird.UR
import com.sparrowwallet.hummingbird.UREncoder
import org.junit.Assert.*
import org.junit.Test

class SigningQrTest {
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
