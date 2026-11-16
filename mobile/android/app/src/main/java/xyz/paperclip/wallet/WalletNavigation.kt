package xyz.paperclip.wallet

/** Each primary tab owns its history. Back returns to the immediate parent. */
internal data class WalletNavigation(
    val tab: String = "Wallet",
    private val stacks: Map<String, List<String>> = emptyMap(),
) {
    private val path get() = stacks[tab] ?: listOf(tab)
    val route get() = path.last()
    val canGoBack get() = path.size > 1
    val depth get() = path.size

    fun open(route: String): WalletNavigation = when {
        route in tabs -> selectTab(route)
        route == this.route -> this
        else -> copy(stacks = stacks + (tab to (path + route)))
    }

    fun selectTab(next: String): WalletNavigation {
        require(next in tabs)
        // Reselecting the current tab returns to its overview.
        return if (next == tab) copy(stacks = stacks - tab) else copy(tab = next)
    }

    fun back(): WalletNavigation = if (canGoBack) copy(stacks = if (path.size == 2) stacks - tab else stacks + (tab to path.dropLast(1))) else this
    fun resetPaths(): WalletNavigation = copy(stacks = emptyMap())
    fun saved(): List<String> = listOf(tab) + tabs.map { (stacks[it] ?: listOf(it)).joinToString("\u001f") }

    companion object {
        val tabs = listOf("Wallet", "Lightning", "Jars", "Activity", "Settings")
        fun restore(saved: List<String>): WalletNavigation {
            // Preserve existing tab histories across the addition of Jars.
            val roots = if (saved.size == 5) listOf("Wallet", "Lightning", "Activity", "Settings") else tabs
            if (saved.size != roots.size + 1 || saved.first() !in roots) return WalletNavigation()
            val stacks = roots.mapIndexed { index, root ->
                val path = saved[index + 1].split('\u001f')
                root to path.takeIf { it.firstOrNull() == root && it.size <= 32 && it.all(String::isNotBlank) }.orEmpty().ifEmpty { listOf(root) }
            }.filter { it.second.size > 1 }.toMap()
            return WalletNavigation(saved.first(), stacks)
        }
    }
}
