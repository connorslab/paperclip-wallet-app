package xyz.paperclip.wallet

import org.junit.Assert.*
import org.junit.Test

class SeedEntropyTest {
	@Test
	fun physicalDiceMatchesIosVectorsAndUsesEveryRoll() {
		val vectors =
			listOf(
				Triple(6, 50, "ec28f632c842726f6ed490c9115f9d32"),
				Triple(12, 36, "28f23d996c90d93745bc88f05c6103c4"),
				Triple(20, 30, "91a93aac185e128e5dd9f7aa027092bf"),
			)
		for ((sides, count, expected) in vectors) {
			val rolls = (0 until count).map { it % sides + 1 }
			assertEquals(count, SeedEntropy.requiredRolls(12, sides))
			assertEquals(count * 2, SeedEntropy.requiredRolls(24, sides))
			assertEquals(
				expected,
				SeedEntropy.dice(rolls, sides, 12).joinToString("") { "%02x".format(it) },
			)
			assertFalse(
				SeedEntropy.dice(rolls, sides, 12)
					.contentEquals(SeedEntropy.dice(rolls + 1, sides, 12)),
			)
			assertThrows(IllegalArgumentException::class.java) {
				SeedEntropy.dice(rolls.dropLast(1), sides, 12)
			}
			assertThrows(IllegalArgumentException::class.java) {
				SeedEntropy.dice(rolls + 0, sides, 12)
			}
		}
	}

	@Test
	fun supplementalSamplesNeverReplaceSystemRandomness() {
		val samples = ByteArray(32) { 2 }
		assertFalse(
			SeedEntropy.mix(ByteArray(32) { 1 }, samples, 24)
				.contentEquals(SeedEntropy.mix(ByteArray(32) { 3 }, samples, 24)),
		)
		assertThrows(IllegalArgumentException::class.java) {
			SeedEntropy.mix(byteArrayOf(), samples, 24)
		}
		assertThrows(IllegalArgumentException::class.java) {
			SeedEntropy.mix(ByteArray(32), byteArrayOf(), 24)
		}
		assertEquals(16, SeedEntropy.system(12).size)
		assertThrows(IllegalArgumentException::class.java) { SeedEntropy.system(15) }
	}
}
