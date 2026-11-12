package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Public iOS signer fixtures; no private keys, network calls or broadcasts. */
class PublicWalletNativeTest {
	@Test
	fun allSignerScriptsImportDeriveAndExportOnlyPublicData() =
		runBlocking<Unit> {
			val engine =
				WalletEngine.shared(InstrumentationRegistry.getInstrumentation().targetContext)
			val original = engine.activeID()
			var created: String? = null
			val fixtures =
				listOf(
					Triple(
						"legacy",
						"[73c5da0a/44h/0h/0h]xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJVVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSSSoekkudhUd9yLb6qx39T9nMdj",
						"1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA",
					),
					Triple(
						"nested",
						"[73c5da0a/49h/0h/0h]xpub6C6nQwHaWbSrzs5tZ1q7m5R9cPK9eYpNMFesiXsYrgc1P8bvLLAet9JfHjYXKjToD8cBRswJXXbbFpXgwsswVPAZzKMa1jUp2kVkGVUaJa7",
						"37VucYSaXLCAsxYyAPfbSi9eh4iEcbShgf",
					),
					Triple(
						"segwit",
						"[73c5da0a/84h/0h/0h]xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V",
						"bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
					),
					Triple(
						"taproot",
						"[73c5da0a/86h/0h/0h]xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ",
						"bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr",
					),
				)
			try {
				for ((script, key, address) in fixtures) {
					for (hardware in listOf(true, false)) {
						engine.importPublic(
							key,
							"",
							script,
							hardware,
							"xbt-mainnet",
							"Public signer fixture",
						)
						val id = checkNotNull(engine.activeID())
						created = id
						assertEquals(address, engine.call("address_onchain").getString("address"))
						val public = engine.exportPublic(id)
						assertFalse(public.has("seed"))
						assertFalse(public.has("phrase"))
						assertFalse(public.has("identity"))
						assertTrue(public.getString("descriptor").isNotBlank())
						engine.close()
						engine.open()
						assertEquals(0L, engine.call("overview_onchain").getLong("total_sat"))
						engine.removeWallet(
							id,
							"Public signer fixture",
							"REMOVE Public signer fixture",
							true,
						)
						created = null
					}
				}
			} finally {
				created?.let {
					engine.removeWallet(
						it,
						"Public signer fixture",
						"REMOVE Public signer fixture",
						true,
					)
				}
				if (original != null && engine.profiles().any { it.id == original })
					engine.select(original)
			}
		}
}
