package xyz.paperclip.wallet

import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Same header, nonce/ciphertext/tag layout and AAD as the iOS CryptoKit archive. */
object BackupCodec {
    private val header = "PAPERCLIP-BACKUP-1\n".toByteArray(Charsets.UTF_8)
    const val MAX_BYTES = 64 * 1024 * 1024
    fun newKey(): String = Base64.getEncoder().encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })
    private fun key(value: String): SecretKeySpec {
        require(value.trim().length <= 64) { "Invalid recovery key" }
        val bytes = Base64.getDecoder().decode(value.trim())
        require(bytes.size == 32) { "Recovery key must decode to 32 bytes" }
        return SecretKeySpec(bytes, "AES").also { bytes.fill(0) }
    }
    fun seal(plain: ByteArray, recoveryKey: String): ByteArray {
        require(plain.size < MAX_BYTES - 64) { "Backup too large" }
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(recoveryKey), GCMParameterSpec(128, nonce))
        cipher.updateAAD(header)
        return header + nonce + cipher.doFinal(plain)
    }
    fun open(bytes: ByteArray, recoveryKey: String): ByteArray {
        require(bytes.size in (header.size + 28)..MAX_BYTES && bytes.copyOfRange(0, header.size).contentEquals(header)) { "Unsupported backup format" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(recoveryKey), GCMParameterSpec(128, bytes.copyOfRange(header.size, header.size + 12)))
        cipher.updateAAD(header)
        return cipher.doFinal(bytes, header.size + 12, bytes.size - header.size - 12)
    }
}
