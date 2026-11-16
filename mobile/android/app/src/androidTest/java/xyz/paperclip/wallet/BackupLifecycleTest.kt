package xyz.paperclip.wallet

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

/** Unfunded local profile; delays export completion without changing native storage. */
class BackupLifecycleTest {
	@Test fun lateExportCannotRestoreAKeyAfterLockOrLeavingThePage() = runBlocking<Unit> {
		val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
		val engine = WalletEngine.shared(app)
		val original = engine.activeID()
		engine.create(engine.phrase(), "xbt-regtest", "Backup lifecycle fixture")
		val created = checkNotNull(engine.activeID())
		val models = ViewModelStore()
		var entered = CompletableDeferred<Unit>()
		var release = CompletableDeferred<Unit>()
		var bytes = ByteArray(32) { 42 }
		val model = withContext(Dispatchers.Main) {
			WalletModel(app) {
				entered.complete(Unit)
				release.await()
				bytes
			}.also { models.put("backup", it) }
		}
		suspend fun idle() { withTimeout(10000) { model.state.first { !it.busy && it.loaded } } }
		try {
			for (lock in listOf(true, false)) {
				withContext(Dispatchers.Main) { model.load(screenshots = true) }
				idle()
				withContext(Dispatchers.Main) { model.prepareBackup() }
				withTimeout(10000) { entered.await() }
				withContext(Dispatchers.Main) { if (lock) model.lock() else model.clearBackup() }
				release.complete(Unit)
				idle()
				assertTrue(model.state.value.recoveryKey.isEmpty())
				assertNull(model.state.value.backup)
				assertTrue("Discarded export bytes were retained", bytes.all { it == 0.toByte() })
				entered = CompletableDeferred(); release = CompletableDeferred(); bytes = ByteArray(32) { 42 }
			}
			// A fresh request can finish. Locking then retains only its encrypted
			// bytes for Android's document picker, never the displayed recovery key.
			release.complete(Unit)
			withContext(Dispatchers.Main) { model.prepareBackup() }
			idle()
			assertTrue(model.state.value.recoveryKey.isNotEmpty())
			assertSame(bytes, model.state.value.backup)
			withContext(Dispatchers.Main) { model.lock() }
			assertTrue(model.state.value.recoveryKey.isEmpty())
			assertSame(bytes, model.state.value.backup)
			withContext(Dispatchers.Main) { model.clearBackup() }
			assertTrue(bytes.all { it == 0.toByte() })
		} finally {
			release.complete(Unit)
			withContext(Dispatchers.Main) { model.clearBackup(); models.clear() }
			val profile = engine.profiles().first { it.id == created }
			engine.removeWallet(created, profile.name, "REMOVE ${profile.name}", true)
			if (original != null && engine.profiles().any { it.id == original }) engine.select(original)
		}
	}
}
