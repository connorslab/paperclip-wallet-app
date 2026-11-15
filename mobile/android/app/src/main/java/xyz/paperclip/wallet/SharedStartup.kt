package xyz.paperclip.wallet

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Callers own their wait, not the shared runtime. Failed attempts can be retried. */
internal class SharedStartup<T>(private val scope: CoroutineScope) {
	private val mutex = Mutex()
	private var running: Deferred<T>? = null

	suspend fun await(start: suspend () -> T): T {
		val task = mutex.withLock {
			running?.takeUnless { it.isCompleted } ?: scope.async(start = CoroutineStart.LAZY) {
				start()
			}.also { running = it; it.start() }
		}
		return task.await()
	}
}
