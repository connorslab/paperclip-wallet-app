package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Creates only unfunded regtest profiles; no backend or transaction is contacted. */
class AssistanceNativeTest {
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
