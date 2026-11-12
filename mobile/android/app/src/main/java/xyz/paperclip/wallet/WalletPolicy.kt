package xyz.paperclip.wallet

import java.net.URI
import org.json.JSONObject

enum class PaymentStatus(val title: String, val detail: String) {
    COMPLETE("Payment succeeded", "The wallet confirmed this payment."),
    SUBMITTED("Transaction submitted", "Waiting for on-chain confirmation."),
    PENDING("Payment pending", "Check status before trying another payment."),
    NOT_SENT("Payment not sent", "Review a new quote before trying again."),
    UNKNOWN("Payment needs checking", "The outcome is uncertain. Sync and check activity before retrying.");
    companion object {
        fun from(value: String) = when (value) {
            "completed", "paid", "settled" -> COMPLETE
            "submitted" -> SUBMITTED
            "pending", "pending_broadcast", "awaiting_payment", "ready_to_claim", "claim_pending", "delivery_pending" -> PENDING
            "not_sent" -> NOT_SENT
            else -> UNKNOWN
        }
    }
}

data class PaymentReview(val destination: String, val amount: Long, val fee: Long,
                         val total: Long, val onchain: Boolean, val created: Long) {
    init { require(amount > 0 && fee >= 0 && total == Math.addExact(amount, fee)) { "Invalid payment quote" } }
    fun valid(now: Long) = now >= created && now - created < 60_000
}

data class Connection(val backend: String = "electrum", val endpoint: String = "ssl://pool.paperclip-xbt.xyz:50002",
    val server: String = "https://ark.paperclip-xbt.xyz", val username: String = "", val password: String = "",
    val proxy: String = "builtin", val certificatePin: String = "") {
    fun validate() {
        require(backend in listOf("electrum", "esplora", "rpc")) { "Choose a chain backend" }
        if (proxy.isNotEmpty() && proxy != "builtin") {
            val p = URI(proxy)
            require(p.scheme == "socks5h" && !p.host.isNullOrBlank() && p.port in 1..65535 &&
                p.rawUserInfo == null && p.rawQuery == null && p.rawFragment == null && p.rawPath.isNullOrEmpty()) {
                "Use socks5h://host:port; DNS must resolve through Tor"
            }
        }
        endpoint(endpoint, if (backend == "electrum") setOf("ssl", "tcp") else setOf("https", "http"))
        endpoint(server, setOf("https", "http"))
        if (backend == "rpc") require(username.isNotBlank() && password.isNotBlank()) { "Enter RPC credentials" }
        require(certificatePin.isEmpty() || certificatePin.matches(Regex("[0-9a-fA-F]{64}"))) { "Certificate pin must contain 64 hexadecimal characters" }
    }
    private fun endpoint(value: String, schemes: Set<String>) {
        val u = URI(value)
        require(value == value.trim() && u.scheme in schemes && !u.host.isNullOrBlank() &&
            u.rawUserInfo == null && u.rawQuery == null && u.rawFragment == null && u.port <= 65535) { "Invalid endpoint; enter credentials separately" }
        val host = u.host.lowercase()
        require(!host.endsWith(".onion") || proxy.isNotEmpty()) { "Onion endpoints require a Tor SOCKS proxy" }
        val local = host == "localhost" || host == "127.0.0.1" || host == "[::1]" ||
            host.matches(Regex("10\\.(\\d{1,3}\\.){2}\\d{1,3}")) ||
            host.matches(Regex("192\\.168\\.\\d{1,3}\\.\\d{1,3}")) ||
            host.matches(Regex("172\\.(1[6-9]|2[0-9]|3[01])\\.\\d{1,3}\\.\\d{1,3}"))
        require(u.scheme !in setOf("http", "tcp") || local || (host.endsWith(".onion") && proxy.isNotEmpty())) {
            "Use TLS for public endpoints. Plain connections are limited to LAN or Tor onion services."
        }
    }
    fun json() = JSONObject().put("backend", backend).put("endpoint", endpoint).put("server", server)
        .put("username", username).put("password", password).put("proxy", proxy).put("certificatePin", certificatePin)
    companion object {
        fun from(j: JSONObject) = Connection(j.getString("backend"), j.getString("endpoint"), j.getString("server"),
            j.optString("username"), j.optString("password"), j.optString("proxy"), j.optString("certificatePin"))
    }
}
