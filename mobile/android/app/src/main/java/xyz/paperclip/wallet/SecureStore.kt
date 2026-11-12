package xyz.paperclip.wallet

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-bound encryption; no keys or wallet databases enter Android cloud backups. */
class SecureStore(context: Context) {
    private val directory = File(context.noBackupFilesDir, "vault").apply { mkdirs() }
    private val alias = "paperclip.android.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(directory.listFiles().isNullOrEmpty()) { "Device key is missing. Restore your full encrypted backup; existing data was preserved." }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUnlockedDeviceRequired(true).build())
        }.generateKey()
    }
    private fun file(name: String): AtomicFile {
        require(name.matches(Regex("[a-z-]+")))
        return AtomicFile(File(directory, name))
    }
    fun read(name: String): ByteArray? {
        val file = file(name)
        if (!file.baseFile.exists()) return null
        val bytes = file.readFully()
        require(bytes.size >= 28) { "Damaged secure storage" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(name.toByteArray())
        return cipher.doFinal(bytes, 12, bytes.size - 12)
    }
    fun write(name: String, bytes: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(name.toByteArray())
        val encrypted = cipher.iv + cipher.doFinal(bytes)
        val file = file(name)
        val stream = file.startWrite()
        try { stream.write(encrypted); file.finishWrite(stream) }
        catch (e: Exception) { file.failWrite(stream); throw e }
    }
}
