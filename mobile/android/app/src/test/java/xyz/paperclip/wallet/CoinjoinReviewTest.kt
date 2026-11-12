package xyz.paperclip.wallet

import org.junit.Assert.*
import org.junit.Test

class CoinjoinReviewTest {
	@Test
	fun reviewedDebitIncludesFeeAndLinkedChange() {
		val review = CoinjoinReview.create(listOf(6000, 6000), 10000, 1, 2.0, 10)
		assertEquals(10000L, review.mixed)
		assertEquals(407L, review.fee)
		assertEquals(1593L, review.change)
		assertEquals(12000L, review.mixed + review.fee + review.change)
	}

	@Test
	fun dustRemainderIsShownAsFee() {
		val review = CoinjoinReview.create(listOf(10300), 10000, 1, 2.0, 10)
		assertEquals(300L, review.fee)
		assertEquals(0L, review.change)
	}

	@Test
	fun invalidTermsAndInsufficientCoinsCannotBeReviewed() {
		assertThrows(IllegalArgumentException::class.java) {
			CoinjoinReview.create(listOf(10000), 10000, 1, 2.0, 10)
		}
		assertThrows(IllegalArgumentException::class.java) {
			CoinjoinReview.create(listOf(20000), 10000, 1, Double.NaN, 10)
		}
		assertThrows(IllegalArgumentException::class.java) {
			CoinjoinReview.create(listOf(20000), 1000, 1, 2.0, 10)
		}
		assertThrows(IllegalArgumentException::class.java) {
			CoinjoinReview.create(listOf(20000, 20000), 10000, 1, 2.0, 1)
		}
	}
}
