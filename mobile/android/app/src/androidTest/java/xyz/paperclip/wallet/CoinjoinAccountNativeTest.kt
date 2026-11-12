package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class CoinjoinAccountNativeTest {
	@Test
	fun unfundedMainnetAccountIsSeparateAndPersistsWithoutNetworking() =
		runBlocking<Unit> {
			val engine =
				WalletEngine.shared(InstrumentationRegistry.getInstrumentation().targetContext)
			val original = engine.activeID()
			var created: String? = null
			try {
				engine.create(engine.phrase(), "xbt-mainnet", "Coinjoin isolation fixture")
				val id = checkNotNull(engine.activeID())
				created = id
				val main = engine.call("address_onchain").getString("address")
				val first = engine.callForWallet(id, "coinjoin_status")
				assertEquals("m/84h/0h/1h", first.getString("account_path"))
				assertEquals(0L, first.getLong("balance_sat"))
				assertNotEquals(main, first.getString("address"))
				engine.close()
				engine.open()
				assertEquals(
					first.getString("address"),
					engine.callForWallet(id, "coinjoin_status").getString("address"),
				)
			} finally {
				created?.let {
					engine.removeWallet(
						it,
						"Coinjoin isolation fixture",
						"REMOVE Coinjoin isolation fixture",
						true,
					)
				}
				if (original != null && engine.profiles().any { it.id == original })
					engine.select(original)
			}
		}
}
