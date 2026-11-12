package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Only newly created, unfunded regtest profiles are removed by this test. */
class WalletProfilesNativeTest {
	@Test
	fun walletRemovalIsScopedAndInterruptedRemovalResumes() =
		runBlocking<Unit> {
			val context = InstrumentationRegistry.getInstrumentation().targetContext
			val engine = WalletEngine.shared(context)
			val original = engine.activeID()
			val created = mutableListOf<String>()
			try {
				engine.create(engine.phrase(), "xbt-regtest", "Removal fixture A")
				val first = checkNotNull(engine.activeID())
				created += first
				engine.savePending(JSONObject().put("state", "not_sent"))
				engine.create(engine.phrase(), "xbt-regtest", "Removal fixture B")
				val second = checkNotNull(engine.activeID())
				created += second
				try {
					engine.removeWallet(first, "Removal fixture A", "wrong", true)
					fail("Missing confirmation accepted")
				} catch (_: IllegalArgumentException) {}
				assertTrue(engine.profiles().any { it.id == first })
				engine.removeWallet(first, "Removal fixture A", "REMOVE Removal fixture A", true)
				created.remove(first)
				assertTrue(engine.profiles().any { it.id == second })
				assertEquals(second, engine.activeID())
				assertNull(engine.pending())
				engine.close()
				// Simulate process death after durable intent but before local deletion.
				SecureStore(context)
					.write(
						"wallet-removal",
						JSONObject().put("id", second).toString().toByteArray(),
					)
				assertFalse(engine.profiles().any { it.id == second })
				created.remove(second)
			} finally {
				for (id in created) {
					val profile = engine.profiles().firstOrNull { it.id == id } ?: continue
					engine.removeWallet(id, profile.name, "REMOVE ${profile.name}", true)
				}
				if (original != null && engine.profiles().any { it.id == original })
					engine.select(original)
			}
		}
}
