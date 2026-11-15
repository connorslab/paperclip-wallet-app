package xyz.paperclip.wallet

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

class SharedStartupTest {
	@Test fun cancelledWaiterDoesNotStopAnotherConsumer() = runBlocking {
		val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
		try {
			val startup = SharedStartup<String>(scope)
			val started = CompletableDeferred<Unit>()
			val finish = CompletableDeferred<Unit>()
			val calls = AtomicInteger()
			val first = async { startup.await { calls.incrementAndGet(); started.complete(Unit); finish.await(); "socks" } }
			started.await()
			val second = async(start = CoroutineStart.UNDISPATCHED) { startup.await { error("Duplicate startup") } }
			first.cancelAndJoin()
			assertFalse(second.isCompleted)
			finish.complete(Unit)
			assertEquals("socks", withTimeout(1000) { second.await() })
			assertEquals(1, calls.get())
		} finally { scope.cancel() }
	}

	@Test fun failedAttemptCanBeRetried() = runBlocking {
		val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
		try {
			val startup = SharedStartup<String>(scope)
			try { startup.await { error("Control unavailable") }; fail() } catch (_: IllegalStateException) {}
			assertEquals("ready", startup.await { "ready" })
		} finally { scope.cancel() }
	}

	@Test fun blockingControlWaitIsInterruptedAtDeadline() = runBlocking {
		val interrupted = CompletableDeferred<Unit>()
		try {
			withTimeout(100) {
				runInterruptible(Dispatchers.IO) {
					try { CountDownLatch(1).await() }
					catch (e: InterruptedException) { interrupted.complete(Unit); throw e }
				}
			}
			fail()
		} catch (_: TimeoutCancellationException) {}
		withTimeout(1000) { interrupted.await() }
	}
}
