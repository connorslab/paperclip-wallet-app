package xyz.paperclip.wallet

import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Explicit opt-in: protected local input, real adapters, read-only operations. */
class NodeLiveTest {
	@Test
	fun startOsLanReadsAndPinRejection() = runBlocking {
		val path = System.getenv("PAPERCLIP_LIVE_CONFIG")
		assumeTrue("Requires explicit private live-node test input", !path.isNullOrBlank())
		val cases = JSONObject(File(checkNotNull(path)).readText()).getJSONArray("cases")
		val implementations = (0 until cases.length()).mapNotNull { index ->
			val connection = cases.getJSONObject(index).getJSONObject("connection")
			if (connection.getBoolean("useTor")) null else connection.getString("implementation")
		}.toSet()
		assertEquals("Supply both CLN and LND LAN cases", setOf("cln", "lnd"), implementations)
		for (index in 0 until cases.length()) {
			val item = cases.getJSONObject(index)
			val config = item.getJSONObject("connection")
			if (config.getBoolean("useTor")) continue
			val c = NodeConnection(
				implementation = config.getString("implementation"), endpoint = config.getString("endpoint"),
				credential = config.getString("credential"), pin = config.getString("certificateSHA256"), proxy = "",
			)
			val node = LightningNode(c, LightningNode.transport(c, ""))
			repeat(3) {
				val info = node.info()
				assertEquals("Trusted node identity", item.getString("expectedIdentity"), info.getString(if (c.implementation == "lnd") "identity_pubkey" else "id"))
				NodeNetwork.decode(info, c.implementation == "lnd")
				node.balance()
			}
			val bad = c.copy(pin = "0".repeat(64))
			var rejected = false
			try { LightningNode(bad, LightningNode.transport(bad, "")).info() }
			catch (_: javax.net.ssl.SSLException) { rejected = true }
			assertTrue("Wrong certificate pin must be rejected", rejected)
			node.info()
			println("Live " + c.implementation + " LAN: identity, three balance reads, pin rejection, recovery passed")
		}
	}
}
