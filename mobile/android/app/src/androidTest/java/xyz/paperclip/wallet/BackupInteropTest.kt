package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Public fixed-seed regtest fixtures only. No connection or payment RPC is used. */
class BackupInteropTest {
	private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
	private fun fixture() = instrumentation.context.assets.open("native-v2-regtest.json").use {
		JSONObject(String(it.readBytes(), Charsets.UTF_8))
	}

	@Test fun nativeArchivePreservesAccountsAndPendingAttempt() {
		val fixture = fixture()
		val archive = fixture.getJSONObject("archive")
		val key = fixture.getString("publicRecoveryKey")
		val plain = archive.toString().toByteArray()
		val encrypted = try { BackupCodec.seal(plain, key) } finally { plain.fill(0) }
		verifyAndExport(encrypted, fixture)
	}

	@Test fun iosArchivePreservesAccountsAndPendingAttempt() {
		val encrypted = instrumentation.context.assets.open("ios-v2-regtest.pcbackup").use { it.readBytes() }
		verifyAndExport(encrypted, fixture())
	}

	@Test fun archiveInstallationPreservesExistingProfileAndRejectsDuplicate() = runBlocking<Unit> {
		val engine = WalletEngine.shared(instrumentation.targetContext)
		val previous = engine.activeID()
		val created = mutableListOf<String>()
		val fixture = fixture()
		val key = fixture.getString("publicRecoveryKey")
		val encrypted = instrumentation.context.assets.open("ios-v2-regtest.pcbackup").use { it.readBytes() }
		try {
			engine.create(engine.phrase(), "xbt-regtest", "Restore isolation fixture")
			val original = checkNotNull(engine.activeID()).also { created.add(it) }
			val address = engine.call("address_onchain").getString("address")
			val count = engine.profiles().size
			val plain = BackupCodec.open(encrypted, key)
			val bad = try { BackupArchive.decode(plain) } finally { plain.fill(0) }
			bad.put("seed", Base64.getEncoder().encodeToString(ByteArray(64) { 30 }))
			val badPlain = bad.toString().toByteArray()
			val badEncrypted = try { BackupCodec.seal(badPlain, key) } finally { badPlain.fill(0) }
			try {
				assertTrue("Wrong wallet archive installed", runCatching { engine.restore(badEncrypted, key, testOnly = true) }.isFailure)
			} finally { badEncrypted.fill(0) }
			assertEquals(original, engine.activeID())
			assertEquals(count, engine.profiles().size)
			fun containsAddress(result: JSONObject): Boolean {
				val addresses = result.getJSONArray("addresses")
				return (0 until addresses.length()).any { addresses.getJSONObject(it).getString("address") == address }
			}
			assertTrue(containsAddress(engine.call("addresses_onchain")))
			engine.restore(encrypted, key, testOnly = true)
			val restored = checkNotNull(engine.activeID()).also { created.add(it) }
			assertNotEquals(original, restored)
			assertEquals(count + 1, engine.profiles().size)
			assertEquals(fixture.getString("attemptID"), engine.pending()?.getString("attempt_id"))
			assertEquals("unknown", engine.pending()?.getString("state"))
			assertTrue("Duplicate wallet installed", runCatching { engine.restore(encrypted, key, testOnly = true) }.isFailure)
			assertEquals(restored, engine.activeID())
			assertEquals(count + 1, engine.profiles().size)
			engine.close()
			engine.open()
			engine.select(original)
			assertTrue(containsAddress(engine.call("addresses_onchain")))
			engine.select(restored)
			assertEquals(fixture.getString("attemptID"), engine.pending()?.getString("attempt_id"))
			assertEquals("unknown", engine.pending()?.getString("state"))
		} finally {
			encrypted.fill(0)
			for (id in created.asReversed()) {
				val profile = engine.profiles().firstOrNull { it.id == id } ?: continue
				engine.removeWallet(id, profile.name, "REMOVE ${profile.name}", true)
			}
			if (previous != null && engine.profiles().any { it.id == previous }) engine.select(previous)
		}
	}

	private fun verifyAndExport(encrypted: ByteArray, fixture: JSONObject) {
		val context = instrumentation.targetContext
		runBlocking { WalletEngine.shared(context).close() }
		val key = fixture.getString("publicRecoveryKey")
		val plain = BackupCodec.open(encrypted, key)
		val archive = try { BackupArchive.decode(plain) } finally { plain.fill(0) }
		assertEquals("xbt-regtest", archive.getString("network"))
		val seed = Base64.getDecoder().decode(archive.getString("seed"))
		val base = File(context.cacheDir, "backup-interop-${UUID.randomUUID()}").apply { mkdirs() }
		fun call(op: String, fields: JSONObject = JSONObject(), secret: ByteArray = seed): JSONObject =
			JSONObject(String(NativeBridge.call(fields.put("op", op).toString().toByteArray(), secret)))
		fun ok(op: String, fields: JSONObject = JSONObject()): JSONObject {
			val result = call(op, fields)
			assertTrue("Synthetic native $op failed", result.has("ok"))
			return result.getJSONObject("ok")
		}
		fun input(network: String = "xbt-regtest") = JSONObject().put("network", network)
			.put("directory", base.absolutePath).put("database", archive.getString("recoveryState"))
		try {
			ok("close")
			assertTrue("Wrong key accepted", call("verify_backup", input(), ByteArray(64) { 30 }).has("error"))
			assertTrue("Wrong network accepted", call("verify_backup", input("xbt-mainnet")).has("error"))
			assertTrue(ok("verify_backup", input()).getBoolean("verified"))
			val restored = File(base, "restored")
			ok("restore", input().put("directory", restored.absolutePath))
			ok("open", JSONObject().put("network", "xbt-regtest").put("directory", restored.absolutePath))
			assertEquals("segwit", ok("overview_onchain").getString("account"))
			val saved = ok("outgoing_payment").getJSONObject("attempt")
			assertEquals(fixture.getString("attemptID"), saved.getString("attempt_id"))
			assertEquals(fixture.getString("paymentHash"), saved.getString("payment_hash"))
			assertEquals("unknown", saved.getString("state"))
			val snapshot = ok("backup")
			assertEquals(2, snapshot.getInt("recovery_version"))
			val exported = JSONObject(archive.toString()).put("recoveryState", snapshot.getString("database"))
			val exportedPlain = exported.toString().toByteArray()
			val bytes = try { BackupCodec.seal(exportedPlain, key) } finally { exportedPlain.fill(0) }
			try {
				val output = File(context.getExternalFilesDir(null), "backup-fixtures").apply { mkdirs() }
				File(output, "android-v2-regtest.pcbackup").writeBytes(bytes)
			} finally { bytes.fill(0) }
			assertEquals(fixture.getString("nextSegwitAddress"), ok("address_onchain").getString("address"))
			ok("select_onchain_account", JSONObject().put("account", "taproot"))
			assertEquals(fixture.getString("nextTaprootAddress"), ok("address_onchain").getString("address"))
			for (op in listOf("quote", "quote_onchain", "send", "send_onchain")) {
				assertTrue("Restored approval or replay was allowed", call(op).optString("error").contains("previous payment"))
			}
		} finally {
			call("close"); seed.fill(0); encrypted.fill(0); base.deleteRecursively()
		}
	}
}
