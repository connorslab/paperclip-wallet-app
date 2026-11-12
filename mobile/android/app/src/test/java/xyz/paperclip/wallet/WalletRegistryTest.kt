package xyz.paperclip.wallet

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WalletRegistryTest {
	private val first = "00000000-0000-4000-8000-000000000001"
	private val second = "00000000-0000-4000-8000-000000000002"

	@Test
	fun migrationAndSelectionKeepDistinctIdentities() {
		val old =
			JSONObject()
				.put("id", first)
				.put("network", "xbt-regtest")
				.put("seed", "synthetic-first")
		val r = WalletRegistry.migrate(old)
		assertEquals(first, r.selected()!!.getString("id"))
		r.put(JSONObject().put("id", second).put("seed", "synthetic-second"))
		assertEquals(2, r.entries().size)
		r.select(first)
		val reopened = WalletRegistry(JSONObject(r.json().toString()))
		assertEquals("synthetic-first", reopened.selected()!!.getString("seed"))
		reopened.rename(second, "Hardware")
		assertEquals(first, reopened.selected()!!.getString("id"))
		assertThrows(IllegalArgumentException::class.java) { reopened.select("missing") }
	}

	@Test
	fun updatingProvisioningDoesNotDuplicateWallet() {
		val r = WalletRegistry.migrate(JSONObject().put("id", first).put("provisioning", true))
		r.put(JSONObject().put("id", first).put("provisioning", false))
		assertEquals(1, r.entries().size)
		assertFalse(r.selected()!!.getBoolean("provisioning"))
	}

	@Test
	fun removalPreservesOtherWalletAndSelectsRemainingProfile() {
		val r = WalletRegistry.migrate(JSONObject().put("id", first))
		r.put(JSONObject().put("id", second))
		r.remove(second)
		assertEquals(first, r.selected()!!.getString("id"))
		assertThrows(IllegalArgumentException::class.java) { r.remove(second) }
		r.remove(first)
		assertNull(WalletRegistry(JSONObject(r.json().toString())).selected())
	}
}
