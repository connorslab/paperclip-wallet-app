package xyz.paperclip.wallet

import org.junit.Assert.*
import org.junit.Test

class PaymentInputTest {
	@Test
	fun scannerExtractsAmountWithoutFloatingPointRounding() {
		val request = PaymentInput.scan("bitcoin:bc1qfixture?amount=0.00000001&label=Example")
		assertEquals("bc1qfixture", request.destination)
		assertEquals(1L, request.amount)
		assertEquals("lnbcfixture", PaymentInput.scan("LIGHTNING:lnbcfixture").destination)
	}

	@Test
	fun unsupportedRequiredOrAmbiguousParametersAreRejected() {
		for (value in
			listOf(
				"bitcoin://host/address",
				"bitcoin:address?req-feature=1",
				"bitcoin:address?amount=1&amount=2",
				"bitcoin:address?amount=0",
				"bitcoin:address?amount=1e2",
				"bitcoin:address?amount=0.000000001",
				"bitcoin:address#fragment",
			)) {
			assertThrows(Exception::class.java) { PaymentInput.scan(value) }
		}
	}
}
