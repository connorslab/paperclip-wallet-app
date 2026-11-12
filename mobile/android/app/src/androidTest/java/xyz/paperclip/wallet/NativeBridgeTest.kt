package xyz.paperclip.wallet

import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class NativeBridgeTest {
    @Test fun nativeBoundaryAndFullDatabaseRecovery() {
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
