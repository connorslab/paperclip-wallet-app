package xyz.paperclip.wallet

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Serializes review/journal transitions across wallet, node and bridge screens. */
internal object PaymentGate {
	private val mutex = Mutex()

	suspend fun <T> run(block: suspend () -> T): T = mutex.withLock { block() }
}
