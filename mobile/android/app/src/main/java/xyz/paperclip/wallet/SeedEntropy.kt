package xyz.paperclip.wallet

import java.security.MessageDigest
import java.security.SecureRandom
import kotlin.math.ceil
import kotlin.math.log2

internal object SeedEntropy {
	fun byteCount(words: Int): Int {
		require(words in listOf(12, 24))
		return if (words == 12) 16 else 32
	}

	fun requiredRolls(words: Int, sides: Int): Int {
		require(sides in listOf(6, 12, 20))
		return ceil(byteCount(words) * 8 / log2(sides.toDouble())).toInt()
	}

	fun system(words: Int) = ByteArray(byteCount(words)).also { SecureRandom().nextBytes(it) }

	fun dice(rolls: List<Int>, sides: Int, words: Int): ByteArray {
		require(rolls.size in requiredRolls(words, sides)..1000 && rolls.all { it in 1..sides }) {
			"Enter enough valid physical dice rolls for the selected die"
		}
		val bytes = ("Paperclip/dice/v1/sides=$sides\n" + rolls.joinToString(",")).toByteArray()
		return try {
			MessageDigest.getInstance("SHA-256").digest(bytes).copyOf(byteCount(words))
		} finally {
			bytes.fill(0)
		}
	}

	fun mix(system: ByteArray, sensorDigest: ByteArray, words: Int): ByteArray {
		val count = byteCount(words)
		require(system.size == count && sensorDigest.size == 32)
		val input =
			"Paperclip/seed-sensors/v1\u0000".toByteArray() +
				byteArrayOf(count.toByte()) +
				system +
				sensorDigest
		return try {
			MessageDigest.getInstance("SHA-256").digest(input).copyOf(count)
		} finally {
			input.fill(0)
		}
	}
}
