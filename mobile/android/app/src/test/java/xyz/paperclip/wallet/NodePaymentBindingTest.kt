package xyz.paperclip.wallet

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NodePaymentBindingTest {
	private val connection = NodeConnection(endpoint = "https://node.example:8180", credential = "aabb", proxy = "")
	private fun legacy() = JSONObject().put("hash", "12".repeat(32)).put("invoice", "synthetic-invoice").put("state", "unknown")

	@Test fun legacyAssignmentPreservesOutcomeWithoutGrantingApproval() {
		val old = legacy()
		assertTrue(NodePaymentBinding.needsReview(old))
		assertThrows(IllegalStateException::class.java) { NodePaymentBinding.requireMatches(old, connection) }
		val assigned = NodePaymentBinding.assign(old, connection)
		assertEquals(old.getString("hash"), assigned.getString("hash"))
		assertEquals(old.getString("invoice"), assigned.getString("invoice"))
		assertEquals("unknown", assigned.getString("state"))
		assertTrue(NodePaymentBinding.needsReview(old))
		assertFalse(NodePaymentBinding.needsReview(assigned))
		NodePaymentBinding.requireMatches(assigned, connection)
		assertEquals(setOf("hash", "invoice", "state", "endpoint", "implementation"), assigned.keys().asSequence().toSet())
		assertThrows(IllegalStateException::class.java) { NodePaymentBinding.assign(assigned, connection) }
	}

	@Test fun differentNodeOrImplementationCannotResolvePayment() {
		val assigned = NodePaymentBinding.assign(legacy(), connection)
		assertThrows(IllegalStateException::class.java) { NodePaymentBinding.requireMatches(assigned, connection.copy(endpoint = "https://another.example")) }
		assertThrows(IllegalStateException::class.java) { NodePaymentBinding.requireMatches(assigned, connection.copy(implementation = "cln")) }
	}

	@Test fun staleReviewCannotReplaceUpdatedAttemptOrConnection() {
		val reviewed = legacy().toString()
		for ((key, value) in listOf("hash" to "34".repeat(32), "invoice" to "another-invoice", "state" to "pending")) {
			val current = legacy().put(key, value)
			assertThrows(IllegalStateException::class.java) { NodePaymentBinding.assignReviewed(current, reviewed, connection, connection) }
			assertTrue(NodePaymentBinding.needsReview(current))
		}
		assertThrows(IllegalStateException::class.java) {
			NodePaymentBinding.assignReviewed(legacy(), reviewed, connection.copy(credential = "ccdd"), connection)
		}
		NodePaymentBinding.requireMatches(NodePaymentBinding.assignReviewed(legacy(), reviewed, connection, connection), connection)
	}

	@Test fun malformedOrPartialLegacyRecordIsNotAssigned() {
		for ((key, value) in listOf("endpoint" to connection.endpoint, "implementation" to "lnd", "hash" to "short", "invoice" to "")) {
			assertThrows(IllegalArgumentException::class.java.takeIf { key in setOf("hash", "invoice") } ?: IllegalStateException::class.java) {
				NodePaymentBinding.assign(legacy().put(key, value), connection)
			}
		}
	}

	@Test fun lateResponseRequiresTheEntireCurrentRecordAndConnection() {
		val original = NodePaymentBinding.assign(legacy(), connection)
		val expected = original.toString()
		NodePaymentBinding.requireCurrent(JSONObject(expected), expected, connection, connection)
		for ((key, value) in listOf("invoice" to "changed", "state" to "succeeded", "endpoint" to "https://other.example")) {
			val changed = JSONObject(expected).put(key, value)
			val before = changed.toString()
			assertThrows(IllegalStateException::class.java) { NodePaymentBinding.requireCurrent(changed, expected, connection, connection) }
			assertEquals(before, changed.toString())
		}
		assertThrows(IllegalStateException::class.java) { NodePaymentBinding.requireCurrent(null, expected, connection, connection) }
		assertThrows(IllegalStateException::class.java) { NodePaymentBinding.requireCurrent(original, expected, null, connection) }
		assertThrows(IllegalStateException::class.java) {
			NodePaymentBinding.requireCurrent(original, expected, connection.copy(credential = "ccdd"), connection)
		}
	}
}
