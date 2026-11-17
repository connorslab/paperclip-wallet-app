package xyz.paperclip.wallet

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Base64
import org.json.JSONObject

/** Portable schema: v2 adds durable native send state inside the SQLite snapshot.
 * Older readers reject v2 instead of silently discarding the replay protection.
 * walletID is legacy display metadata, not proof of seed/database ownership;
 * the native restore validator must still verify that relationship.
 */
internal object BackupArchive {
	fun decode(plain: ByteArray): JSONObject = try {
		val text = Charsets.UTF_8.newDecoder()
			.onMalformedInput(CodingErrorAction.REPORT)
			.onUnmappableCharacter(CodingErrorAction.REPORT)
			.decode(ByteBuffer.wrap(plain)).toString()
		JSONObject(text).also(::validate)
	} catch (_: Exception) {
		// Android JSON parser exceptions may contain the complete source text,
		// including the seed. Do not propagate them into UI errors or logs.
		throw IllegalArgumentException("Invalid or unsupported wallet backup")
	}

	fun validate(archive: JSONObject) {
		fun text(name: String): String = (archive.opt(name) as? String)
			?: throw IllegalArgumentException("Invalid backup metadata")
		// JSONObject.getInt/getString coerce strings, booleans and fractional
		// numbers. Never use that coercion to choose a recovery format.
		val version = archive.opt("version") as? Number
		require(version != null && version.toDouble() in listOf(1.0, 2.0)) { "Unsupported backup format" }
		require(text("network") in listOf("xbt-mainnet", "xbt-regtest")) { "Unsupported backup network" }
		val id = text("walletID")
		require(id.isNotEmpty() && id.toByteArray(Charsets.UTF_8).size <= 128) { "Invalid backup metadata" }
		val createdAt = archive.opt("createdAt") as? Number
		require(createdAt != null && createdAt.toDouble().isFinite()) { "Invalid backup date" }
		val phrase = archive.opt("seedPhrase")
		require(phrase == null || phrase == JSONObject.NULL ||
			(phrase is String && phrase.toByteArray(Charsets.UTF_8).size <= 4096)) { "Invalid backup words" }
		fun data(name: String, size: (Int) -> Boolean) {
			val encoded = text(name)
			val decoded = Base64.getDecoder().decode(encoded)
			try {
				require(size(decoded.size) && Base64.getEncoder().encodeToString(decoded) == encoded) {
					"Invalid backup recovery data"
				}
			} finally { decoded.fill(0) }
		}
		data("seed") { it == 64 }
		data("recoveryState") { it > 0 }
	}
}
