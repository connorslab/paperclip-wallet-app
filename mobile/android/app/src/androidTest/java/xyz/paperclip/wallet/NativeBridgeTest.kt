package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.runBlocking

class NativeBridgeTest {
    @Test fun collidingFingerprintDoesNotAuthorizeAnotherSeedAcrossJni() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        runBlocking { WalletEngine.shared(context).close() }
        fun fixture(counter: Long) = ByteArray(64).also { ByteBuffer.wrap(it).order(ByteOrder.LITTLE_ENDIAN).putLong(counter) }
        val seed = fixture(68878); val other = fixture(85331)
        val base = File(context.cacheDir, "binding-${UUID.randomUUID()}")
        fun call(key: ByteArray, request: JSONObject) = JSONObject(String(NativeBridge.call(request.toString().toByteArray(), key)))
        try {
            val created = call(seed, JSONObject().put("op", "create").put("network", "xbt-regtest").put("directory", base.absolutePath))
            assertTrue("Fixture creation failed", created.has("ok"))
            val rejected = call(other, JSONObject().put("op", "overview_onchain"))
            assertTrue("A colliding fingerprint authorized the wrong seed", rejected.has("error"))
            assertTrue("Original session must remain usable", call(seed, JSONObject().put("op", "overview_onchain")).has("ok"))
        } finally {
            call(seed, JSONObject().put("op", "close"))
            seed.fill(0); other.fill(0); base.deleteRecursively()
        }
    }

    @Test fun nativeBoundaryAndFullDatabaseRecovery() {
        runBlocking { WalletEngine.shared(InstrumentationRegistry.getInstrumentation().targetContext).close() }
        val seed = ByteArray(64) { 37 }
        fun call(op: String, fields: JSONObject = JSONObject()): JSONObject {
            val response = JSONObject(String(NativeBridge.call(fields.put("op", op).toString().toByteArray(), seed)))
            check(!response.has("error")) { response.optString("error") }
            return response.getJSONObject("ok")
        }
        assertThrows(IllegalArgumentException::class.java) { NativeBridge.call("{}".toByteArray(), ByteArray(63)) }
        assertThrows(IllegalArgumentException::class.java) { NativeBridge.call(byteArrayOf(0), seed) }
        val base = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, UUID.randomUUID().toString()).apply { mkdirs() }
        try {
            call("close")
            call("create", JSONObject().put("network", "xbt-regtest").put("directory", File(base, "first").absolutePath))
            for (operation in listOf("send", "send_onchain")) {
                // A consumed/missing quote cannot prove an earlier send failed.
                assertThrows(IllegalStateException::class.java) {
                    call(operation, JSONObject().put("destination", "unreviewed recipient")
                        .put("amount_sat", 1000).put("total_sat", 1100))
                }
            }
            val address = call("address_onchain").getString("address")
            assertTrue(address.startsWith("bcrt1"))
            val backup = call("backup")
            val next = call("address_onchain").getString("address")
            assertNotEquals(address, next)
            call("close")
            call("restore", JSONObject().put("network", "xbt-regtest").put("directory", File(base, "restored").absolutePath).put("database", backup.getString("database")))
            call("open", JSONObject().put("network", "xbt-regtest").put("directory", File(base, "restored").absolutePath))
            assertEquals(next, call("address_onchain").getString("address"))
            assertEquals(0L, call("overview_onchain").getLong("total_sat"))
        } finally { call("close"); seed.fill(0); base.deleteRecursively() }
    }
}
