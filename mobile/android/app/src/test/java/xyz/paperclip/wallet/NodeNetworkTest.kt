package xyz.paperclip.wallet

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NodeNetworkTest {
	@Test
	fun networksMatchIosAndDoNotDefaultUnknownNodesToMainnet() {
		assertEquals(
			NodeNetwork.MAINNET,
			NodeNetwork.decode(
				JSONObject("""{"chains":[{"chain":"bitcoin","network":"mainnet"}]}"""),
				true,
			),
		)
		assertEquals(
			NodeNetwork.REGTEST,
			NodeNetwork.decode(JSONObject("""{"network":"regtest"}"""), false),
		)
		for (json in
			listOf(
				"""{"chains":[]}""",
				"""{"chains":[{"chain":"bitcoin","network":"testnet"}]}""",
			)) assertThrows(Exception::class.java) { NodeNetwork.decode(JSONObject(json), true) }
		assertThrows(Exception::class.java) {
			NodeNetwork.decode(JSONObject("""{"network":"unknown"}"""), false)
		}
		assertFalse(NodeNetwork.MAINNET.accepts("lnbcrt1fixture"))
		assertFalse(NodeNetwork.REGTEST.accepts("lnbc1fixture"))
		assertTrue(NodeNetwork.REGTEST.accepts("lnbcrt1fixture"))
	}
}
