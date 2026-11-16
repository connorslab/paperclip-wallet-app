package xyz.paperclip.wallet

import android.app.Application
import android.net.Uri
import java.io.File
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Uses only unfunded profiles and preserves the pre-existing encrypted journal. */
class WalletSelectionStateTest {
    @Test fun unreadablePaymentMetadataCannotSeparateDisplayedAndNativeWallets() = runBlocking<Unit> {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        val engine = WalletEngine.shared(app)
        val vault = SecureStore(app)
        val original = engine.activeID()
        val previousPending = vault.read("wallet-pending")
        val created = mutableListOf<String>()
        val models = ViewModelStore()
        var model: WalletModel? = null
        try {
            engine.create(engine.phrase(), "xbt-regtest", "Selection target fixture")
            val target = checkNotNull(engine.activeID()); created += target
            engine.savePending(JSONObject().put("state", "unknown").put("payment_hash", "public-fixture-hash"))
            engine.create(engine.phrase(), "xbt-regtest", "Selection active fixture")
            val active = checkNotNull(engine.activeID()); created += active
            val validPending = checkNotNull(vault.read("wallet-pending"))
            val viewModel = withContext(Dispatchers.Main) { WalletModel(app).also { models.put("selection", it) } }
            model = viewModel
            suspend fun idle() { withTimeout(10000) { viewModel.state.first { !it.busy && it.loaded } } }
            withContext(Dispatchers.Main) { viewModel.load(screenshots = true) }
            idle()
            assertEquals(active, viewModel.state.value.activeID)
            try {
                for (damaged in listOf("invalid json", JSONObject().put(target, "invalid record type").toString(), JSONObject().put(target, JSONObject.NULL).toString())) {
                    vault.write("wallet-pending", damaged.toByteArray())
                    withContext(Dispatchers.Main) { viewModel.selectWallet(target) }
                    idle()
                    assertEquals("Unreadable payment status committed a different native wallet", active, engine.activeID())
                    assertEquals(active, viewModel.state.value.activeID)
                    assertNotNull("Unreadable status was silently treated as no payment", viewModel.state.value.error)
                    assertEquals(0L, engine.call("overview_onchain").getLong("total_sat"))
                }
                vault.write("wallet-pending", validPending)
                val validRegistry = checkNotNull(vault.read("wallet-registry"))
                try {
                    val damaged = JSONObject(String(validRegistry, Charsets.UTF_8))
                    val wallets = damaged.getJSONArray("wallets")
                    val targetRecord = (0 until wallets.length()).map { wallets.getJSONObject(it) }.first { it.getString("id") == target }
                    targetRecord.put("connection", "invalid connection type")
                    vault.write("wallet-registry", damaged.toString().toByteArray())
                    withContext(Dispatchers.Main) { viewModel.selectWallet(target) }
                    idle()
                    assertEquals(active, engine.activeID())
                    assertEquals(active, viewModel.state.value.activeID)
                    assertNotNull(viewModel.state.value.error)
                } finally { vault.write("wallet-registry", validRegistry); validRegistry.fill(0) }
                withContext(Dispatchers.Main) { viewModel.selectWallet(target) }
                idle()
                assertNull(viewModel.state.value.error)
                assertEquals(target, engine.activeID())
                assertEquals(target, viewModel.state.value.activeID)
                assertEquals("unknown", viewModel.state.value.result?.getString("state"))
                assertEquals("public-fixture-hash", viewModel.state.value.result?.getString("payment_hash"))
            } finally { validPending.fill(0) }
        } finally {
            withContext(Dispatchers.Main) { model?.clearBackup(); models.clear() }
            if (previousPending != null) { vault.write("wallet-pending", previousPending); previousPending.fill(0) }
            else vault.delete("wallet-pending")
            for (id in created) {
                val profile = engine.profiles().firstOrNull { it.id == id } ?: continue
                engine.removeWallet(id, profile.name, "REMOVE ${profile.name}", true)
            }
            if (original != null && engine.profiles().any { it.id == original }) engine.select(original)
        }
    }

    @Test fun newAndRestoredProfilesKeepTheDisplayedConnectionAndClearOldReceiveState() = runBlocking<Unit> {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        val engine = WalletEngine.shared(app)
        val vault = SecureStore(app)
        val original = engine.activeID()
        val globalConnection = vault.read("connection")
        val created = mutableListOf<String>()
        val models = ViewModelStore()
        val archiveFile = File(app.cacheDir, "qa-profile-connection-backup")
        check(!archiveFile.exists()) { "Preserve existing backup fixture" }
        var model: WalletModel? = null
        try {
            engine.create(engine.phrase(), "xbt-regtest", "Connection source fixture")
            val source = checkNotNull(engine.activeID()); created += source
            val selected = Connection(endpoint = "ssl://selected.example:50002", server = "https://selected.example")
            val legacy = Connection(endpoint = "ssl://legacy.example:50002", server = "https://legacy.example")
            val registryBytes = checkNotNull(vault.read("wallet-registry"))
            try {
                val registry = JSONObject(String(registryBytes, Charsets.UTF_8))
                val wallets = registry.getJSONArray("wallets")
                (0 until wallets.length()).map { wallets.getJSONObject(it) }
                    .first { it.getString("id") == source }.put("connection", selected.json())
                val updated = registry.toString().toByteArray()
                try { vault.write("wallet-registry", updated) } finally { updated.fill(0) }
            } finally { registryBytes.fill(0) }
            vault.write("connection", legacy.json().toString().toByteArray())
            engine.close()
            val viewModel = withContext(Dispatchers.Main) { WalletModel(app).also { models.put("profiles", it) } }
            model = viewModel
            suspend fun idle() { withTimeout(10000) { viewModel.state.first { !it.busy && it.loaded } } }
            suspend fun loadAndReceive() {
                withContext(Dispatchers.Main) { viewModel.load(screenshots = true) }
                idle()
                withContext(Dispatchers.Main) { viewModel.receive("On-chain") }
                idle()
                assertTrue(viewModel.state.value.address.isNotEmpty())
            }
            suspend fun assertSelectedState() {
                assertNull(viewModel.state.value.error)
                assertEquals(engine.activeID(), viewModel.state.value.activeID)
                assertEquals(selected.endpoint, engine.connection().endpoint)
                assertEquals(selected.endpoint, viewModel.state.value.connection.endpoint)
                assertEquals("Previous wallet receive address survived a profile change", "", viewModel.state.value.address)
                engine.close(); engine.open()
                assertEquals(selected.endpoint, engine.connection().endpoint)
            }
            loadAndReceive()
            val phrase = engine.phrase()
            withContext(Dispatchers.Main) { viewModel.addWallet(phrase, "Connection target fixture") }
            idle()
            val target = checkNotNull(engine.activeID()); created += target
            assertSelectedState()
            val key = BackupCodec.newKey()
            val archive = engine.backup(key)
            try { archiveFile.writeBytes(archive) } finally { archive.fill(0) }
            val profile = engine.profiles().first { it.id == target }
            engine.removeWallet(target, profile.name, "REMOVE ${profile.name}", true)
            engine.select(source)
            loadAndReceive()
            withContext(Dispatchers.Main) { viewModel.restoreBackupFile(Uri.fromFile(archiveFile), key) }
            idle()
            val restored = checkNotNull(engine.activeID()); created += restored
            assertNotEquals(source, restored)
            assertSelectedState()
            // Settings are copied to each profile, not a live reference to the
            // legacy fallback. Switching back still reads the source's settings.
            engine.select(source)
            assertEquals(selected.endpoint, engine.connection().endpoint)
            loadAndReceive()
            // Public signing fixture only; no signer or broadcast is involved.
            val publicKey = "[73c5da0a/84h/0h/0h]tpubDCxX2sYFS5bDkSe5GKKYHjBW7tgyN1R3UchpLJvdbf54ohxeGRtd8MbDUe1cguVHe4vnK68DsuD5MXjxi9EXx16rb9EnNsaF5KT99CinaJz"
            withContext(Dispatchers.Main) { viewModel.importPublic(publicKey, "", "segwit", true, "Connection signer fixture") }
            idle()
            assertNull(viewModel.state.value.error)
            val signer = checkNotNull(engine.activeID()); created += signer
            assertNotEquals(source, signer)
            assertSelectedState()
        } finally {
            archiveFile.delete()
            withContext(Dispatchers.Main) { model?.clearBackup(); models.clear() }
            if (globalConnection != null) { vault.write("connection", globalConnection); globalConnection.fill(0) }
            else vault.delete("connection")
            for (id in created.distinct()) {
                val profile = engine.profiles().firstOrNull { it.id == id } ?: continue
                engine.removeWallet(id, profile.name, "REMOVE ${profile.name}", true)
            }
            if (original != null && engine.profiles().any { it.id == original }) engine.select(original)
        }
    }

}
