package xyz.paperclip.wallet

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Exercises JNI and the actual shared jar validator without opening a wallet. */
class JoinBlaketNativeTest {
	@Test fun jarsKeepIdentityAndRejectUnknownAccounts() {
		val coin = JSONObject().put("utxo", "00".repeat(32) + ":0").put("value", 12345)
			.put("mixdepth", 3).put("confirmations", 0).put("frozen", false)
		fun call(): JSONObject {
			val input = JSONObject().put("op", "joinblaket_jars").put("utxos", JSONArray().put(coin))
			return JSONObject(String(NativeBridge.call(input.toString().toByteArray(), ByteArray(64))))
		}
		val jars = call().getJSONObject("ok").getJSONArray("jars")
		assertEquals(5, jars.length())
		assertEquals("Date", jars.getJSONObject(3).getString("name"))
		assertEquals(12345L, jars.getJSONObject(3).getLong("pending_sat"))
		assertEquals(0L, jars.getJSONObject(3).getLong("confirmed_sat"))
		coin.put("mixdepth", 5)
		assertTrue(call().has("error"))
	}
}
