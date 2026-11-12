package xyz.paperclip.wallet

import kotlin.math.ceil

internal data class CoinjoinReview(val mixed: Long, val fee: Long, val change: Long) {
	companion object {
		fun create(
			inputs: List<Long>,
			denomination: Long,
			outputs: Int,
			rate: Double,
			limit: Int,
		): CoinjoinReview {
			require(inputs.size in 1..minOf(limit, 10) && inputs.all { it > 0 })
			require(denomination in 1000..100000000 && outputs in 1..5)
			require(rate.isFinite() && rate in 1.0..500.0)
			val total = inputs.fold(0L, Math::addExact)
			val mixed = Math.multiplyExact(denomination, outputs.toLong())
			require(mixed >= 10000 && total >= mixed)
			val base = 68.0 * inputs.size + 31.0 * outputs + 5.25
			val withChange = ceil(rate * (base + 31)).toLong()
			val withoutChange = ceil(rate * base).toLong()
			val excess = total - mixed
			require(excess >= withoutChange)
			val change = if (excess > withChange + 294) excess - withChange else 0
			return CoinjoinReview(mixed, excess - change, change)
		}
	}
}
