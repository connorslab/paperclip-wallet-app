package xyz.paperclip.wallet

import com.sparrowwallet.hummingbird.Bytewords
import com.sparrowwallet.hummingbird.ResultType
import com.sparrowwallet.hummingbird.URDecoder
import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.zip.Inflater

internal object SigningQr {
	const val MAX = 160 * 1024
	private const val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

	fun frames(data: ByteArray): List<String> {
		require(data.isNotEmpty() && data.size <= MAX)
		val text = base32(data)
		val parts = text.chunked(240)
		require(parts.size <= 1295)
		fun number(n: Int) = n.toString(36).uppercase().padStart(2, '0')
		return parts.mapIndexed { i, s -> "B\$2P${number(parts.size)}${number(i)}$s" }
	}

	fun base32(data: ByteArray): String {
		var acc = 0
		var bits = 0
		val out = StringBuilder()
		for (b in data) {
			acc = (acc shl 8) or (b.toInt() and 255)
			bits += 8
			while (bits >= 5) {
				bits -= 5
				out.append(alphabet[(acc shr bits) and 31])
			}
			acc = acc and ((1 shl bits) - 1)
		}
		if (bits > 0) out.append(alphabet[(acc shl (5 - bits)) and 31])
		return out.toString()
	}

	fun decode32(text: String): ByteArray {
		require(text.length % 8 in listOf(0, 2, 4, 5, 7))
		val out = ByteArrayOutputStream()
		var acc = 0
		var bits = 0
		for (c in text) {
			val n = alphabet.indexOf(c)
			require(n >= 0)
			acc = (acc shl 5) or n
			bits += 5
			if (bits >= 8) {
				bits -= 8
				out.write((acc shr bits) and 255)
			}
			acc = acc and ((1 shl bits) - 1)
		}
		require(acc == 0)
		return out.toByteArray()
	}

	fun binary(text: String): ByteArray {
		val s = text.trim()
		require(s.length <= MAX * 2)
		val bytes =
			if (s.length % 2 == 0 && s.matches(Regex("[0-9a-fA-F]+")))
				s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
			else Base64.getDecoder().decode(s)
		require(bytes.isNotEmpty() && bytes.size <= MAX)
		return bytes
	}

	fun inflate(data: ByteArray): ByteArray {
		val inflater = Inflater(true)
		try {
			inflater.setInput(data)
			val out = ByteArray(MAX + 1)
			val count = inflater.inflate(out)
			require(count <= MAX && inflater.finished() && inflater.remaining == 0)
			return out.copyOf(count)
		} finally {
			inflater.end()
		}
	}
}

internal class SigningQrCollector {
	private var identity: String? = null
	private val parts = mutableMapOf<Int, String>()
	private var size = 0
	private var decoder: URDecoder? = null
	private val seen = mutableSetOf<String>()
	var total = 0
		private set

	val received
		get() = decoder?.receivedPartIndexes?.size ?: parts.size

	fun accept(frame: String, publicWallet: Boolean = false): ByteArray? {
		require(frame.length <= 4096) { "QR frame too large" }
		if (frame.lowercase().startsWith("ur:")) {
			require(!publicWallet && parts.isEmpty()) { "Unsupported or mixed QR request" }
			return ur(frame)
		}
		require(decoder == null) { "Mixed QR requests" }
		if (frame.startsWith("B\$")) {
			require(
				frame.length > 8 &&
					frame[2] in "H2Z" &&
					frame[3] in if (publicWallet) "UJ" else "PT",
			)
			val count = frame.substring(4, 6).toInt(36)
			val index = frame.substring(6, 8).toInt(36)
			require(count in 1..1295 && index in 0 until count)
			insert(frame.substring(8), index, count, frame.take(6))
			if (parts.size != total) return null
			val out = ByteArrayOutputStream()
			for (i in 0 until total) out.write(
				if (frame[2] == 'H') SigningQr.binary(parts.getValue(i))
				else SigningQr.decode32(parts.getValue(i)),
			)
			val raw = out.toByteArray()
			val result = if (frame[2] == 'Z') SigningQr.inflate(raw) else raw
			require(result.size <= SigningQr.MAX)
			return result
		}
		val match = Regex("p([0-9]+)of([0-9]+) (.+)").matchEntire(frame)
		if (match != null) {
			val index = match.groupValues[1].toInt()
			val count = match.groupValues[2].toInt()
			require(count in 1..1295 && index in 1..count)
			insert(match.groupValues[3], index - 1, count, "p$count")
			if (parts.size != total) return null
			val text = (0 until total).joinToString("") { parts.getValue(it) }
			return if (publicWallet) text.toByteArray() else SigningQr.binary(text)
		}
		require(identity == null) { "Mixed QR requests" }
		return if (publicWallet) frame.toByteArray() else SigningQr.binary(frame)
	}

	private fun insert(part: String, index: Int, count: Int, header: String) {
		require(identity == null || (identity == header && total == count)) { "Mixed QR requests" }
		parts[index]?.let {
			require(it == part) { "Conflicting QR frame" }
			return
		}
		require(size + part.length <= SigningQr.MAX * 2)
		identity = header
		total = count
		parts[index] = part
		size += part.length
	}

	private fun ur(frame: String): ByteArray? {
		val normalized = frame.lowercase()
		val fields = normalized.split('/')
		require(fields.size in 2..3 && fields[0] == "ur:crypto-psbt") { "Scan a crypto-psbt UR" }
		val raw = Bytewords.decode(fields.last(), Bytewords.Style.MINIMAL)
		if (fields.size == 2) {
			require(identity == null)
			total = 1
			return Cbor(raw).payload()
		}
		val c = Cbor(raw)
		require(c.byte() == 0x85)
		val seq = c.number(0)
		val count = c.number(0)
		val length = c.number(0)
		val checksum = c.number(0)
		val bytes = c.blob(2048)
		require(
			c.finished() &&
				seq in 1..Int.MAX_VALUE.toLong() &&
				count in 1..1295 &&
				length in 1..(SigningQr.MAX + 8).toLong() &&
				checksum <= 0xffffffffL,
		)
		require(
			bytes.isNotEmpty() &&
				bytes.size * (count - 1) < length &&
				length <= bytes.size * count &&
				fields[1] == "$seq-$count",
		)
		val id = "$count:$length:$checksum:${bytes.size}"
		require(identity == null || identity == id) { "Mixed UR requests" }
		identity = id
		total = count.toInt()
		require(seen.size < 4096 || normalized in seen) { "Too many QR fragments" }
		if (!seen.add(normalized)) return null
		val d = decoder ?: URDecoder().also { decoder = it }
		require(d.receivePart(normalized)) { "Invalid UR fragment" }
		val result = d.result ?: return null
		require(result.type == ResultType.SUCCESS)
		return Cbor(result.ur.cborBytes).payload()
	}

	/** Only fixed arrays, unsigned integers and byte strings; no recursive CBOR allocation. */
	private class Cbor(private val raw: ByteArray) {
		private var pos = 0

		fun byte(): Int {
			require(pos < raw.size)
			return raw[pos++].toInt() and 255
		}

		fun finished() = pos == raw.size

		fun number(major: Int): Long {
			val head = byte()
			require(head shr 5 == major)
			val n = head and 31
			if (n < 24) return n.toLong()
			val width =
				when (n) {
					24 -> 1
					25 -> 2
					26 -> 4
					27 -> 8
					else -> error("Invalid CBOR length")
				}
			var value = 0L
			repeat(width) {
				require(value <= Long.MAX_VALUE ushr 8)
				value = (value shl 8) or byte().toLong()
			}
			return value
		}

		fun blob(max: Int): ByteArray {
			val length = number(2)
			require(length <= max && length <= raw.size - pos)
			return raw.copyOfRange(pos, pos + length.toInt()).also { pos += length.toInt() }
		}

		fun payload() = blob(SigningQr.MAX).also { require(it.isNotEmpty() && finished()) }
	}
}
