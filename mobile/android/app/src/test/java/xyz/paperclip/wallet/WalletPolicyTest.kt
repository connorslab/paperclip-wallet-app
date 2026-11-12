package xyz.paperclip.wallet

import org.junit.Assert.*
import org.junit.Test

class WalletPolicyTest {
    @Test fun pendingIsNotSuccess() {
        listOf("pending", "pending_broadcast", "awaiting_payment", "delivery_pending").forEach {
            assertEquals(PaymentStatus.PENDING, PaymentStatus.from(it))
        }
        assertEquals(PaymentStatus.UNKNOWN, PaymentStatus.from("unexpected"))
        assertEquals(PaymentStatus.SUBMITTED, PaymentStatus.from("submitted"))
        assertEquals(PaymentStatus.COMPLETE, PaymentStatus.from("paid"))
        assertEquals(PaymentStatus.NOT_SENT, PaymentStatus.from("not_sent"))
    }
    @Test fun rejectsStaleOrInconsistentQuote() {
        val q = PaymentReview("destination", 1000, 10, 1010, false, 10_000)
        assertTrue(q.valid(69_999)); assertFalse(q.valid(70_000)); assertFalse(q.valid(9_999))
        assertThrows(IllegalArgumentException::class.java) { PaymentReview("x", 1, 2, 4, false, 0) }
        assertThrows(ArithmeticException::class.java) { PaymentReview("x", Long.MAX_VALUE, 1, 0, false, 0) }
    }
    @Test fun transportCannotSilentlyDowngrade() {
        Connection().validate()
        Connection(backend = "rpc", endpoint = "http://192.168.1.20:8332", username = "user", password = "pw").validate()
        listOf("http://example.com", "https://user:pw@example.com", "https://example.com?secret=x", "http://10.evil.com").forEach { url ->
            assertThrows(IllegalArgumentException::class.java) { Connection(server = url).validate() }
        }
        assertThrows(IllegalArgumentException::class.java) { Connection(server = "http://example.onion").validate() }
        assertThrows(IllegalArgumentException::class.java) { Connection(proxy = "socks5://localhost:9050").validate() }
        Connection(server = "http://example.onion", proxy = "socks5h://127.0.0.1:9050").validate()
    }
    @Test fun backupIsAuthenticatedAndUsesFreshNonce() {
        val key = BackupCodec.newKey(); val plain = "complete wallet archive".toByteArray()
        val first = BackupCodec.seal(plain, key); val second = BackupCodec.seal(plain, key)
        assertFalse(first.contentEquals(second)); assertArrayEquals(plain, BackupCodec.open(first, key))
        first[first.lastIndex] = (first.last().toInt() xor 1).toByte()
        assertThrows(Exception::class.java) { BackupCodec.open(first, key) }
        assertThrows(Exception::class.java) { BackupCodec.open(second, BackupCodec.newKey()) }
        assertThrows(IllegalArgumentException::class.java) { BackupCodec.open(ByteArray(20), key) }
    }
}
