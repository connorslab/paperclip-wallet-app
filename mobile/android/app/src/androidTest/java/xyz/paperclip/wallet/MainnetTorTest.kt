package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.util.UUID

/** Explicitly invoked live test: no existing wallet, payments or production writes. */
class MainnetTorTest {
    @Test fun electrsThroughEmbeddedTor() = runBlocking {
        org.junit.Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("liveTor") == "true")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val proxy = EmbeddedTor.proxy(context)
        val seed = ByteArray(64).also { java.security.SecureRandom().nextBytes(it) }
        val directory = File(context.cacheDir, "tor-probe-${UUID.randomUUID()}")
        fun call(op: String, fields: JSONObject = JSONObject()): JSONObject {
            val response = JSONObject(String(NativeBridge.call(fields.put("op", op).toString().toByteArray(), seed)))
            check(!response.has("error")) { response.optString("error") }
            return response.getJSONObject("ok")
        }
        try {
            WalletEngine.shared(context).close()
            call("create", JSONObject().put("directory", directory.absolutePath).put("network", "xbt-mainnet"))
            val config = call("config_template").put("electrum_address", "ssl://pool.paperclip-xbt.xyz:50002")
                .put("server_address", "https://ark.paperclip-xbt.xyz").put("socks5_proxy", proxy)
                .put("esplora_address", JSONObject.NULL).put("bitcoind_address", JSONObject.NULL)
            call("connect", JSONObject().put("config", config))
            val health = call("chain_health")
            assertTrue(health.getBoolean("connected"))
            android.util.Log.i("PaperclipTorProbe", "Tor mainnet Electrs health: $health")
            call("sync_onchain")
            assertEquals(0L, call("overview_onchain").getLong("total_sat"))
            assertEquals(0L, call("sync_ark").getLong("ark_sat"))
            android.util.Log.i("PaperclipTorProbe", "Mainnet Electrs and ASP synchronization passed over Tor")
            call("close")
            call("open", JSONObject().put("directory", directory.absolutePath).put("network", "xbt-mainnet"))
            config.put("socks5_proxy", "socks5h://127.0.0.1:1")
            var rejected = false
            try { call("connect", JSONObject().put("config", config)); call("chain_health") }
            catch (_: IllegalStateException) { rejected = true }
            assertTrue("Dead Tor proxy must not fall back to direct networking", rejected)
        } finally { call("close"); seed.fill(0); directory.deleteRecursively() }
    }
}
