package xyz.paperclip.wallet

import org.junit.Assert.*
import org.junit.Test

class ArkRpcConnectionTest {
	@Test
	fun independentlyRoutedArkRpcSurvivesEncryptedRecordEncoding() {
		val rpc =
			ArkRpcConnection("http://node.onion:8332", "test-user", "test-password", "builtin")
		val connection = Connection(proxy = "", arkRpc = rpc)
		connection.validate()
		assertEquals(connection, Connection.from(connection.json()))
		assertNull(Connection.from(Connection().json()).arkRpc)
	}

	@Test
	fun arkOnionCannotInheritDirectChainRoute() {
		assertThrows(IllegalArgumentException::class.java) {
			Connection(
					arkRpc =
						ArkRpcConnection(
							"http://node.onion:8332",
							"test-user",
							"test-password",
							"",
						),
				)
				.validate()
		}
		assertThrows(IllegalArgumentException::class.java) {
			Connection(arkRpc = ArkRpcConnection("https://example.com", "", "", "")).validate()
		}
	}
}
