package xyz.paperclip.wallet

import android.app.Application
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
}
