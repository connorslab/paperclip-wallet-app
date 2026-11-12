package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.net.Socket
import java.util.UUID

/** Local regtest controller only. Never accepts a production backend. */
class FundedRecoveryTest {
    private fun lab(path: String, data: JSONObject = JSONObject()): JSONObject {
        Socket("10.0.2.2", 39444).use { socket ->
            socket.soTimeout = 60_000
            val body = data.toString().toByteArray()
            socket.getOutputStream().apply {
                write("POST /$path HTTP/1.0\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\n\r\n".toByteArray()); write(body); flush()
            }
            val response = socket.getInputStream().bufferedReader().readText()
            check(response.substringBefore("\r\n").matches(Regex("HTTP/1\\.[01] 200.*"))) { response.take(600) }
            return JSONObject(response.substringAfter("\r\n\r\n"))
        }
    }
    @Test fun fundedBackupAndExitWithAspOffline(): Unit = runBlocking {
        org.junit.Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("fundedRecovery") == "true")
        assertEquals("regtest", lab("rpc", JSONObject().put("method", "getblockchaininfo")).getJSONObject("result").getString("chain"))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        WalletEngine.shared(context).close()
        val seed = ByteArray(64).also { java.security.SecureRandom().nextBytes(it) }
        val base = File(context.cacheDir, "recovery-${UUID.randomUUID()}")
        fun call(op: String, fields: JSONObject = JSONObject()): JSONObject {
            val response = JSONObject(String(NativeBridge.call(fields.put("op", op).toString().toByteArray(), seed)))
            check(!response.has("error")) { "$op: ${response.optString("error")}" }
            return response.getJSONObject("ok")
        }
        try {
            call("create", JSONObject().put("network", "xbt-regtest").put("directory", File(base,"original").absolutePath))
            val config = call("config_template").put("electrum_address", JSONObject.NULL).put("esplora_address", JSONObject.NULL)
                .put("bitcoind_address", "http://10.0.2.2:39444/rpc").put("bitcoind_user", "regtest").put("bitcoind_pass", "regtest")
                .put("server_address", "http://10.0.2.2:39535").put("socks5_proxy", JSONObject.NULL)
            call("connect", JSONObject().put("config", config))
            val address = call("address_onchain").getString("address")
            assertTrue(address.startsWith("bcrt1"))
            lab("fund", JSONObject().put("address", address)); lab("mine", JSONObject().put("blocks", 3))
            call("sync_onchain")
            val onchainQuote = call("quote_onchain", JSONObject().put("destination", address).put("amount_sat", 20_000))
            val onchainSend = call("send_onchain", JSONObject().put("destination", address).put("amount_sat", 20_000)
                .put("total_sat", onchainQuote.getLong("total_sat")))
            assertEquals("submitted", onchainSend.getString("state"))
            lab("mine", JSONObject().put("blocks", 1)); call("sync_onchain")
            val quote = call("quote_board", JSONObject().put("amount_sat", 500_000))
            call("board", JSONObject().put("amount_sat",500_000).put("total_sat",quote.getLong("total_sat")))
            lab("mine", JSONObject().put("blocks", 12))
            var balance = 0L
            for (attempt in 0 until 20) {
                balance = call("sync_ark").getLong("ark_sat")
                if (balance > 0) break
                kotlinx.coroutines.delay(1000)
            }
            assertTrue(balance > 0)
            val arkAddress = call("address_ark").getString("address")
            val arkQuote = call("quote", JSONObject().put("destination", arkAddress).put("amount_sat", 10_000))
            val arkSend = call("send", JSONObject().put("destination", arkAddress).put("amount_sat", 10_000)
                .put("total_sat", arkQuote.getLong("total_sat")))
            assertEquals("completed", arkSend.getString("state"))
            assertTrue(call("sync_ark").getLong("ark_sat") > 0)
            android.util.Log.i("PaperclipRecovery", "Funded on-chain send, boarding and Ark send passed")
            val key = BackupCodec.newKey()
            val archive = BackupCodec.seal(call("backup").getString("database").toByteArray(),key)
            call("close")
            lab("offline")
            call("restore", JSONObject().put("network","xbt-regtest").put("directory",File(base,"restored").absolutePath)
                .put("database",String(BackupCodec.open(archive,key))))
            call("open", JSONObject().put("network","xbt-regtest").put("directory",File(base,"restored").absolutePath))
            call("connect",JSONObject().put("config",config))
            call("exit_start",JSONObject().put("confirmed",true))
            var claimable = false
            for (step in 0 until 80) {
                call("exit_progress")
                val status = call("exit_status")
                if (status.getInt("claimable_count") > 0 && !status.getBoolean("pending")) { claimable=true; break }
                val tip = lab("rpc", JSONObject().put("method", "getblockcount")).getLong("result")
                val blocks = (status.optLong("claimable_height", tip + 1) - tip).coerceIn(1, 150)
                lab("mine",JSONObject().put("blocks",blocks))
            }
            assertTrue("Offline exit must become claimable",claimable)
            val result=call("exit_claim",JSONObject().put("confirmed",true).put("destination",address))
            assertEquals("submitted",result.getString("state"))
            lab("mine",JSONObject().put("blocks",1))
            val transaction = lab("rpc",JSONObject().put("method","getrawtransaction").put("params",org.json.JSONArray().put(result.getString("txid")).put(true))).getJSONObject("result")
            assertTrue(transaction.getInt("confirmations") >= 1)
            android.util.Log.i("PaperclipRecovery", "Funded Android backup restored; ASP-offline exit confirmed: ${result.getString("txid")}")
        } finally { call("close"); seed.fill(0); base.deleteRecursively() }
    }
}
