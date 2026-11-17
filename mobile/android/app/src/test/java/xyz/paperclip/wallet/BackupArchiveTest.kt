package xyz.paperclip.wallet

import java.util.Base64
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class BackupArchiveTest {
	@Test fun malformedPayloadDoesNotEscapeIntoErrors() {
		val marker = "PUBLIC-TEST-SECRET-MARKER"
		val error = assertThrows(IllegalArgumentException::class.java) {
			BackupArchive.decode("{\"seedPhrase\":\"$marker\", INVALID".toByteArray())
		}
		assertFalse(error.toString().contains(marker))
		assertNull(error.cause)
		assertThrows(IllegalArgumentException::class.java) { BackupArchive.decode(byteArrayOf(0xC3.toByte(), 0x28)) }
	}
	@Test fun portableSchemaAndCryptoFixture() {
		val fixture = javaClass.classLoader!!.getResourceAsStream("backup-archive-v1.json")!!.use {
			JSONObject(it.bufferedReader().readText())
		}
		val original = fixture.getJSONObject("archive")
		val encrypted = Base64.getDecoder().decode(fixture.getString("encrypted"))
		val plain = BackupCodec.open(encrypted, fixture.getString("publicTestKey"))
		val decoded = try { BackupArchive.decode(plain) } finally { plain.fill(0) }
		assertEquals(original.getString("walletID"), decoded.getString("walletID"))
		assertEquals(original.getString("seed"), decoded.getString("seed"))
		assertEquals(original.getString("recoveryState"), decoded.getString("recoveryState"))
		val cases = fixture.getJSONArray("invalid")
		for (index in 0 until cases.length()) {
			val test = cases.getJSONObject(index)
			val modified = JSONObject(original.toString())
			test.optJSONObject("replace")?.let { replacements ->
				for (field in replacements.keys()) modified.put(field, replacements.get(field))
			}
			if (test.has("remove")) modified.remove(test.getString("remove"))
			assertThrows(test.getString("name"), Exception::class.java) {
				BackupArchive.decode(modified.toString().toByteArray())
			}
		}
		val old = JSONObject(original.toString()).also { it.remove("seedPhrase") }
		BackupArchive.validate(old)
		BackupArchive.validate(JSONObject(original.toString()).put("version", 2))
	}
	@Test fun exportCannotExceedImportLimit() {
		assertThrows(IllegalArgumentException::class.java) {
			BackupCodec.seal(ByteArray(BackupCodec.MAX_BYTES), BackupCodec.newKey())
		}
	}
}
