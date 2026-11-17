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
            // These used to pass JSONObject's coercing getters. Rejection must
            // happen before either check or import can touch the active session.
            val validPlain = BackupCodec.open(archive, key)
            val valid = try { JSONObject(String(validPlain, Charsets.UTF_8)) } finally { validPlain.fill(0) }
            for ((field, value) in listOf("version" to 1.9, "version" to "1",
                "seedPhrase" to false, "walletID" to "", "createdAt" to "yesterday")) {
                val malformed = JSONObject(valid.toString()).put(field, value).toString().toByteArray()
                val invalid = try { BackupCodec.seal(malformed, key) } finally { malformed.fill(0) }
                try {
                    try { engine.checkBackup(invalid, key); fail("Malformed metadata passed restore check") }
                    catch (_: IllegalArgumentException) {}
                    assertStillOpen()
                    try { engine.restore(invalid, key, testOnly = true); fail("Malformed metadata was imported") }
                    catch (_: IllegalArgumentException) {}
                    assertStillOpen()
                } finally { invalid.fill(0) }
            }
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

    @Test fun failedRestoreRegistrationPreservesActiveWalletAndAllowsRetry() = runBlocking<Unit> {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val engine = WalletEngine.shared(context)
        val original = engine.activeID()
        val created = mutableListOf<String>()
        val blocker = java.io.File(context.noBackupFilesDir, "vault/wallet-registry.new")
        check(!blocker.exists()) { "Atomic storage staging already exists; preserve it" }
        var ownsBlocker = false
        var archive: ByteArray? = null
        var activeSeed: ByteArray? = null
        try {
            engine.create(engine.phrase(), "xbt-regtest", "Restore commit source")
            val source = checkNotNull(engine.activeID()); created += source
            val sourceAddress = engine.call("address_onchain").getString("address")
            val key = BackupCodec.newKey()
            val bytes = engine.backup(key); archive = bytes
            engine.create(engine.phrase(), "xbt-regtest", "Restore commit active")
            val active = checkNotNull(engine.activeID()); created += active
            val activeKey = BackupCodec.newKey()
            val encrypted = engine.backup(activeKey)
            val plain = try { BackupCodec.open(encrypted, activeKey) } finally { encrypted.fill(0) }
            activeSeed = try { Base64.getDecoder().decode(JSONObject(String(plain, Charsets.UTF_8)).getString("seed")) } finally { plain.fill(0) }
            val sourceProfile = engine.profiles().first { it.id == source }
            engine.removeWallet(source, sourceProfile.name, "REMOVE ${sourceProfile.name}", true)
            engine.open()
            val profiles = engine.profiles()
            val directories = java.io.File(context.noBackupFilesDir, "wallets").list().orEmpty().toSet()
            // Fail the real AtomicFile commit after native restore/open. The base
            // registry remains readable; no production-only failure hooks needed.
            check(blocker.mkdir()); ownsBlocker = true
            java.io.File(blocker, "fixture").writeText("block atomic write")
            try { engine.restore(bytes, key, testOnly = true); fail("Blocked registration succeeded") }
            catch (_: java.io.IOException) {}
            assertEquals(active, engine.activeID())
            assertEquals(profiles, engine.profiles())
            val reply = NativeBridge.call("{\"op\":\"overview_onchain\"}".toByteArray(), checkNotNull(activeSeed))
            try { assertTrue("Failed registration left the original native wallet closed", JSONObject(String(reply, Charsets.UTF_8)).has("ok")) }
            finally { reply.fill(0) }
            assertEquals(directories, java.io.File(context.noBackupFilesDir, "wallets").list().orEmpty().toSet())
            check(blocker.deleteRecursively()); ownsBlocker = false
            engine.restore(bytes, key, testOnly = true)
            val restored = checkNotNull(engine.activeID()); created += restored
            assertNotEquals(active, restored)
            assertTrue(engine.checkBackup(bytes, key))
            val addresses = engine.call("addresses_onchain").toString()
            assertTrue("Restored wallet lost its receive address", addresses.contains(sourceAddress))
        } finally {
            if (ownsBlocker) blocker.deleteRecursively()
            archive?.fill(0); activeSeed?.fill(0)
            for (id in created) {
                val profile = engine.profiles().firstOrNull { it.id == id } ?: continue
                engine.removeWallet(id, profile.name, "REMOVE ${profile.name}", true)
            }
            if (original != null && engine.profiles().any { it.id == original }) engine.select(original)
        }
    }

    @Test fun failedNewProfileRegistrationPreservesActiveWalletAndAllowsRetry() = runBlocking<Unit> {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val engine = WalletEngine.shared(context)
        val original = engine.activeID()
        val created = mutableListOf<String>()
        val blocker = java.io.File(context.noBackupFilesDir, "vault/wallet-registry.new")
        check(!blocker.exists()) { "Atomic storage staging already exists; preserve it" }
        var ownsBlocker = false
        var activeSeed: ByteArray? = null
        try {
            engine.create(engine.phrase(), "xbt-regtest", "Creation active fixture")
            val active = checkNotNull(engine.activeID()); created += active
            val backupKey = BackupCodec.newKey()
            val encrypted = engine.backup(backupKey)
            val plain = try { BackupCodec.open(encrypted, backupKey) } finally { encrypted.fill(0) }
            activeSeed = try { Base64.getDecoder().decode(JSONObject(String(plain, Charsets.UTF_8)).getString("seed")) } finally { plain.fill(0) }
            val phrase = engine.phrase()
            val publicKey = "[73c5da0a/84h/0h/0h]xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V"
            for (isPublic in listOf(false, true)) {
                suspend fun install() {
                    if (isPublic) engine.importPublic(publicKey, "", "segwit", true, "xbt-mainnet", "Creation public fixture")
                    else engine.create(phrase, "xbt-regtest", "Creation hot fixture")
                }
                val profiles = engine.profiles()
                val directories = java.io.File(context.noBackupFilesDir, "wallets").list().orEmpty().toSet()
                check(blocker.mkdir()); ownsBlocker = true
                java.io.File(blocker, "fixture").writeText("block atomic write")
                try { install(); fail("Blocked new profile registration succeeded") }
                catch (_: java.io.IOException) {}
                assertEquals(active, engine.activeID())
                assertEquals(profiles, engine.profiles())
                val reply = NativeBridge.call("{\"op\":\"overview_onchain\"}".toByteArray(), checkNotNull(activeSeed))
                try { assertTrue("Failed profile creation left the original native wallet closed", JSONObject(String(reply, Charsets.UTF_8)).has("ok")) }
                finally { reply.fill(0) }
                assertEquals(directories, java.io.File(context.noBackupFilesDir, "wallets").list().orEmpty().toSet())
                check(blocker.deleteRecursively()); ownsBlocker = false
                install()
                val id = checkNotNull(engine.activeID()); created += id
                assertNotEquals(active, id)
                assertEquals(if (isPublic) "hardware" else "hot", engine.profiles().first { it.id == id }.kind)
                assertTrue(engine.call("address_onchain").getString("address").startsWith(if (isPublic) "bc1" else "bcrt1"))
                engine.select(active)
            }
        } finally {
            if (ownsBlocker) blocker.deleteRecursively()
            activeSeed?.fill(0)
            for (id in created) {
                val profile = engine.profiles().firstOrNull { it.id == id } ?: continue
                engine.removeWallet(id, profile.name, "REMOVE ${profile.name}", true)
            }
            if (original != null && engine.profiles().any { it.id == original }) engine.select(original)
        }
    }

    @Test fun rejectedWalletSwitchPreservesSelectionSessionAndAllowsRetry() = runBlocking<Unit> {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val engine = WalletEngine.shared(context)
        val original = engine.activeID()
        val created = mutableListOf<String>()
        val blocker = java.io.File(context.noBackupFilesDir, "vault/wallet-registry.new")
        check(!blocker.exists()) { "Atomic storage staging already exists; preserve it" }
        var ownsBlocker = false
        var database: java.io.File? = null
        var held: java.io.File? = null
        var activeSeed: ByteArray? = null
        try {
            engine.create(engine.phrase(), "xbt-regtest", "Switch target fixture")
            val target = checkNotNull(engine.activeID()); created += target
            val targetAddress = engine.call("address_onchain").getString("address")
            engine.create(engine.phrase(), "xbt-regtest", "Switch active fixture")
            val active = checkNotNull(engine.activeID()); created += active
            val key = BackupCodec.newKey()
            val encrypted = engine.backup(key)
            val plain = try { BackupCodec.open(encrypted, key) } finally { encrypted.fill(0) }
            activeSeed = try { Base64.getDecoder().decode(JSONObject(String(plain, Charsets.UTF_8)).getString("seed")) } finally { plain.fill(0) }
            val profiles = engine.profiles()
            val db = java.io.File(context.noBackupFilesDir, "wallets/$target/db.sqlite"); database = db
            val saved = java.io.File(db.parentFile, "fixture-held.sqlite"); held = saved
            check(!saved.exists())
            for (missingDatabase in listOf(true, false)) {
                if (missingDatabase) check(db.renameTo(saved))
                else {
                    check(blocker.mkdir()); ownsBlocker = true
                    java.io.File(blocker, "fixture").writeText("block atomic selection write")
                }
                try { engine.select(target); fail("Unavailable wallet switch succeeded") }
                catch (error: Exception) {
                    assertTrue(if (missingDatabase) error is IllegalStateException else error is java.io.IOException)
                }
                assertEquals("Failed switch changed the persistent selection", active, engine.activeID())
                assertEquals(profiles, engine.profiles())
                val reply = NativeBridge.call("{\"op\":\"overview_onchain\"}".toByteArray(), checkNotNull(activeSeed))
                try { assertTrue("Failed switch closed the original native wallet", JSONObject(String(reply, Charsets.UTF_8)).has("ok")) }
                finally { reply.fill(0) }
                if (missingDatabase) { assertFalse(db.exists()); check(saved.renameTo(db)) }
                else { check(blocker.deleteRecursively()); ownsBlocker = false }
            }
            engine.select(target)
            assertEquals(target, engine.activeID())
            assertTrue(engine.call("addresses_onchain").toString().contains(targetAddress))
        } finally {
            if (ownsBlocker) blocker.deleteRecursively()
            if (held?.exists() == true) check(held!!.renameTo(checkNotNull(database)))
            activeSeed?.fill(0)
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
