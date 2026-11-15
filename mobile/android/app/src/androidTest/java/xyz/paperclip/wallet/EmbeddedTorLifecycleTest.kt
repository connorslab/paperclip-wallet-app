package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in real embedded runtime, without wallet creation or payment requests. */
class EmbeddedTorLifecycleTest {
	@Test fun cancellingOneWaiterKeepsSharedBootstrapAndRetryUsable() = runBlocking {
		assumeTrue(InstrumentationRegistry.getArguments().getString("liveTor") == "true")
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		val first = async { EmbeddedTor.proxy(context) }
		delay(500)
		val second = async { EmbeddedTor.proxy(context) }
		first.cancelAndJoin()
		val endpoint = withTimeout(190_000) { second.await() }
		assertTrue(endpoint.startsWith("socks5h://127.0.0.1:"))
		assertEquals("Tor connected", EmbeddedTor.status.value)
		assertEquals(endpoint, withTimeout(15_000) { EmbeddedTor.proxy(context) })
	}
}
