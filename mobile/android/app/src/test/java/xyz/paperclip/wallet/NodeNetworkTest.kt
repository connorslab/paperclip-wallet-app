package xyz.paperclip.wallet

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NodeNetworkTest {
	@Test
	fun malformedRunesFailBeforeNetworkAccess() {
		val c = NodeConnection(implementation = "cln", endpoint = "https://node.invalid", credential = "test-rune_01==", proxy = "")
		c.validate()
		c.copy(pin = "a".repeat(64) + ", " + "B".repeat(64)).validate()
		for (badPin in listOf(",", "a".repeat(64) + ",", List(5) { "a".repeat(64) }.joinToString(",")))
			assertThrows(IllegalArgumentException::class.java) { c.copy(pin = badPin).validate() }
		for (bad in listOf("rune%2Bescaped", "\"rune\"", "clnrest://node?rune=value", "rune.with.punctuation", "rune value"))
			assertThrows(IllegalArgumentException::class.java) { c.copy(credential = bad).validate() }
	}

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
