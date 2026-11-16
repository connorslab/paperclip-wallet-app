package xyz.paperclip.wallet

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.nio.file.Files
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-bound encryption; no keys or wallet databases enter Android cloud backups. */
class SecureStore(context: Context) {
	companion object {
		// AtomicFile has no locking. Models use separate SecureStore instances,
		// so protect key creation and each complete file operation process-wide.
		private val storageLock = Any()
	}

	private val directory = File(context.noBackupFilesDir, "vault").apply { mkdirs() }
	private val alias = "paperclip.android.v1"

	private fun key(): SecretKey {
		val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
		(store.getKey(alias, null) as? SecretKey)?.let {
			return it
		}
		check(directory.listFiles().isNullOrEmpty()) {
			"Device key is missing. Restore your full encrypted backup; existing data was preserved."
		}
		return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
			.apply {
				init(
					KeyGenParameterSpec.Builder(
							alias,
							KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
						)
						.setBlockModes(KeyProperties.BLOCK_MODE_GCM)
						.setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
						.setUnlockedDeviceRequired(true)
						.build(),
				)
			}
			.generateKey()
	}

	private fun file(name: String): AtomicFile {
		require(name.matches(Regex("[a-z-]+")))
		return AtomicFile(File(directory, name))
	}

	fun read(name: String): ByteArray? = synchronized(storageLock) {
		val file = file(name)
		// AtomicFile must recover a committed legacy backup before deciding
		// the record is absent. A base-file check skips that recovery.
		val bytes = try { file.readFully() } catch (failure: FileNotFoundException) {
			if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()) throw failure
			return@synchronized null
		}
		require(bytes.size >= 28) { "Damaged secure storage" }
		val cipher = Cipher.getInstance("AES/GCM/NoPadding")
		cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
		cipher.updateAAD(name.toByteArray())
		cipher.doFinal(bytes, 12, bytes.size - 12)
	}

	fun write(name: String, bytes: ByteArray) = synchronized(storageLock) {
		val cipher = Cipher.getInstance("AES/GCM/NoPadding")
		cipher.init(Cipher.ENCRYPT_MODE, key())
		cipher.updateAAD(name.toByteArray())
		val encrypted = cipher.iv + cipher.doFinal(bytes)
		val file = file(name)
		val stream = file.startWrite()
		try {
			stream.write(encrypted)
			// AtomicFile logs sync/rename errors without throwing. Propagate a
			// failed sync before commit, then verify the committed ciphertext.
			stream.fd.sync()
			file.finishWrite(stream)
		} catch (e: Exception) {
			file.failWrite(stream)
			throw e
		}
		// Do not call failWrite after finishWrite: older Android versions can
		// delete the committed base file. Readback is not a power-loss guarantee.
		if (!file.readFully().contentEquals(encrypted)) {
			throw IOException("Could not confirm saved wallet data. Check storage and try again.")
		}
	}

	fun delete(name: String) = synchronized(storageLock) {
		val base = file(name).baseFile
		// AtomicFile.delete ignores failures. Remove recovery/staging files
		// first, so a failed backup deletion cannot resurrect a deleted base.
		try {
			for (path in listOf(File(base.path + ".bak"), File(base.path + ".new"), base)) {
				Files.deleteIfExists(path.toPath())
			}
		} catch (failure: IOException) {
			throw IOException("Could not remove saved wallet data. Check device storage before retrying removal.", failure)
		}
	}
}
