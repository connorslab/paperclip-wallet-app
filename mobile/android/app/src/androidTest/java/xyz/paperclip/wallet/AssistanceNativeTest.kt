package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import java.util.Base64

/** Creates only unfunded regtest profiles; no backend or transaction is contacted. */
class AssistanceNativeTest {
    @Test fun rejectedRestoreKeepsTheNativeWalletOpen() = runBlocking<Unit> {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val engine = WalletEngine.shared(context)
        val original = engine.activeID()
        val created = mutableListOf<String>()
        var bytes: ByteArray? = null
        var activeSeed: ByteArray? = null
        try {
            engine.create(engine.phrase(), "xbt-regtest", "Restore archive fixture")
            val source = checkNotNull(engine.activeID()); created += source
            val key = BackupCodec.newKey()
            val archive = engine.backup(key); bytes = archive
            engine.create(engine.phrase(), "xbt-regtest", "Restore active fixture")
            val active = checkNotNull(engine.activeID()); created += active
            val activeKey = BackupCodec.newKey()
            val encrypted = engine.backup(activeKey)
            val plain = try { BackupCodec.open(encrypted, activeKey) } finally { encrypted.fill(0) }
            activeSeed = try { Base64.getDecoder().decode(JSONObject(String(plain, Charsets.UTF_8)).getString("seed")) } finally { plain.fill(0) }
            suspend fun assertStillOpen() {
                assertEquals(active, engine.activeID())
                // Call JNI directly: engine.open() would conceal an unwanted close.
                val reply = NativeBridge.call("{\"op\":\"overview_onchain\"}".toByteArray(), checkNotNull(activeSeed))
                try { assertTrue("Rejected restore closed the native wallet", JSONObject(String(reply, Charsets.UTF_8)).has("ok")) }
                finally { reply.fill(0) }
            }
            try { engine.restore(archive, BackupCodec.newKey(), testOnly = true); fail("Wrong key accepted") }
            catch (_: javax.crypto.AEADBadTagException) {}
            assertStillOpen()
            try { engine.restore(archive, key, testOnly = true); fail("Duplicate wallet accepted") }
            catch (_: IllegalStateException) {}
            assertStillOpen()
            val sourceProfile = engine.profiles().first { it.id == source }
            engine.removeWallet(source, sourceProfile.name, "REMOVE ${sourceProfile.name}", true)
            engine.open()
            val decoded = BackupCodec.open(archive, key)
            val damaged = try { JSONObject(String(decoded, Charsets.UTF_8)).put("recoveryState", Base64.getEncoder().encodeToString("invalid database".toByteArray())) }
            finally { decoded.fill(0) }
            val encoded = damaged.toString().toByteArray()
            val corrupt = try { BackupCodec.seal(encoded, key) } finally { encoded.fill(0) }
            try {
                try { engine.restore(corrupt, key, testOnly = true); fail("Damaged database accepted") }
                catch (_: IllegalStateException) {}
            } finally { corrupt.fill(0) }
            assertStillOpen()
        } finally {
            bytes?.fill(0); activeSeed?.fill(0)
            for (id in created) {
                val profile = engine.profiles().firstOrNull { it.id == id } ?: continue
                engine.removeWallet(id, profile.name, "REMOVE ${profile.name}", true)
            }
            if (original != null && engine.profiles().any { it.id == original }) engine.select(original)
        }
    }

    @Test fun transfersAndBackupChecksPreserveSourceIdentity() = runBlocking<Unit> {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val engine = WalletEngine.shared(context)
        val original = engine.activeID()
        val created = mutableListOf<String>()
        var backup: ByteArray? = null
        try {
            engine.create(engine.phrase(), "xbt-regtest", "Assistance source fixture")
            val source = checkNotNull(engine.activeID()); created += source
            val key = BackupCodec.newKey()
            val bytes = engine.backup(key); backup = bytes
            assertTrue(engine.checkBackup(bytes, key))
            assertEquals(source, engine.activeID())
            try { engine.checkBackup(bytes, BackupCodec.newKey()); fail("Wrong backup key accepted") } catch (_: javax.crypto.AEADBadTagException) {}
            engine.create(engine.phrase(), "xbt-regtest", "Assistance destination fixture")
            val target = checkNotNull(engine.activeID()); created += target
            assertFalse(engine.checkBackup(bytes, key))
            engine.select(source)
            val first = engine.walletDestinationAddress(target)
            val second = engine.walletDestinationAddress(target)
            assertNotEquals(first, second)
            assertTrue(first.startsWith("bcrt1"))
            assertEquals(source, engine.activeID())
            try { engine.walletDestinationAddress(source); fail("Same-wallet target accepted") } catch (_: IllegalArgumentException) {}
            assertFalse(java.io.File(context.noBackupFilesDir, "wallets").listFiles().orEmpty().any { it.name.startsWith("backup-check-") })
        } finally {
            backup?.fill(0)
            for(id in created) {
                val profile = engine.profiles().firstOrNull { it.id == id } ?: continue
                engine.removeWallet(id, profile.name, "REMOVE ${profile.name}", true)
            }
            if(original != null && engine.profiles().any { it.id == original }) engine.select(original)
        }
    }
}
