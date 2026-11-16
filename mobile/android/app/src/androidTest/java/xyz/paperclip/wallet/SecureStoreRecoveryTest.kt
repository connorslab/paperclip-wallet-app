package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.crypto.AEADBadTagException
import org.junit.Assert.*
import org.junit.Test

/** Uses only named non-secret fixtures; never moves an app wallet record. */
class SecureStoreRecoveryTest {
    @Test fun separateStoreInstancesCannotReadOrReplaceAnIncompleteWrite() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val name = "qa-atomic-concurrent"
        val base = File(context.noBackupFilesDir, "vault/$name")
        check(listOf(base, File(base.path + ".bak"), File(base.path + ".new")).none { it.exists() }) { "Preserve existing recovery fixtures" }
        val pool = Executors.newFixedThreadPool(3)
        val start = CountDownLatch(1)
        try {
            val tasks = (0..2).map { worker ->
                pool.submit {
                    val store = SecureStore(context)
                    check(start.await(10, TimeUnit.SECONDS))
                    repeat(12) { revision ->
                        store.write(name, "fixture-$worker-$revision".toByteArray())
                        val observed = String(checkNotNull(store.read(name)))
                        assertTrue("Read an incomplete record", observed.matches(Regex("fixture-[0-2]-([0-9]|1[01])")))
                    }
                }
            }
            start.countDown()
            tasks.forEach { it.get(20, TimeUnit.SECONDS) }
        } finally {
            start.countDown()
            pool.shutdownNow()
            check(pool.awaitTermination(10, TimeUnit.SECONDS))
            SecureStore(context).delete(name)
        }
    }

    @Test fun failedReplacementIsReportedAndCanBeRetried() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = SecureStore(context)
        val name = "qa-atomic-commit"
        val base = File(context.noBackupFilesDir, "vault/$name")
        check(listOf(base, File(base.path + ".bak"), File(base.path + ".new")).none { it.exists() }) { "Preserve existing recovery fixtures" }
        val value = "Non-secret replacement fixture".toByteArray()
        val blocker = File(base, "keep")
        try {
            // A nonempty destination directory allows the staging write but
            // prevents its final rename on current Android AtomicFile.
            check(base.mkdir())
            blocker.writeText("Preserve unrelated contents")
            try { store.write(name, value); fail("Failed replacement was reported as saved") }
            catch (_: IOException) {}
            assertEquals("Preserve unrelated contents", blocker.readText())
            check(blocker.delete())
            check(base.delete())
            store.write(name, value)
            assertArrayEquals(value, store.read(name))
            val replacement = "Non-secret second revision".toByteArray()
            store.write(name, replacement)
            assertArrayEquals(replacement, store.read(name))
        } finally {
            blocker.delete()
            if (base.isDirectory) base.delete()
            store.delete(name)
            value.fill(0)
        }
    }

    @Test fun interruptedLegacyWriteRestoresTheCommittedCiphertext() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = SecureStore(context)
        val name = "qa-atomic-recovery"
        val base = File(context.noBackupFilesDir, "vault/$name")
        val backup = File(base.path + ".bak")
        check(listOf(base, backup, File(base.path + ".new")).none { it.exists() }) { "Preserve existing recovery fixtures" }
        val value = "Non-secret committed storage fixture".toByteArray()
        try {
            store.write(name, value)
            // API 28 can stop after moving the old ciphertext to its backup.
            // Current Android must also recover this state after an OS upgrade.
            check(base.renameTo(backup))
            assertFalse(base.exists())
            assertArrayEquals("Committed backup was treated as missing storage", value, store.read(name))
            assertTrue(base.isFile)
            assertFalse(backup.exists())
            assertArrayEquals(value, store.read(name))
        } finally { store.delete(name); value.fill(0) }
    }

    @Test fun missingIsDistinctFromDamagedAuthenticatedStorage() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = SecureStore(context)
        val name = "qa-atomic-damaged"
        val base = File(context.noBackupFilesDir, "vault/$name")
        check(listOf(base, File(base.path + ".bak"), File(base.path + ".new")).none { it.exists() }) { "Preserve existing recovery fixtures" }
        try {
            assertNull(store.read(name))
            store.write(name, "Non-secret authentication fixture".toByteArray())
            val bytes = base.readBytes()
            bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
            base.writeBytes(bytes)
            try { store.read(name); fail("Damaged ciphertext was accepted or treated as missing") }
            catch (_: AEADBadTagException) {}
        } finally { store.delete(name) }
    }
}
