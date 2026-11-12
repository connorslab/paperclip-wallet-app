package xyz.paperclip.wallet

import org.junit.Assert.*
import org.junit.Test

class SensorHealthTest {
	@Test
	fun repeatedSamplesCannotBeReportedAsValidatedEntropy() {
		val health = SensorHealth()
		repeat(3) { health.observe(ByteArray(4096) { 7 }) }
		assertEquals(2, health.repeated)
		assertEquals(1, health.distinct)
		assertEquals("Repetitive input detected", health.status)
	}

	@Test
	fun diagnosticsBoundSamplingAndDoNotAssignSecurityBits() {
		val health = SensorHealth()
		repeat(3) { packet -> health.observe(ByteArray(100000) { (it + packet).toByte() }) }
		assertEquals(3 * 4096, health.sampled)
		assertEquals("Variation observed · entropy not validated", health.status)
	}
}
