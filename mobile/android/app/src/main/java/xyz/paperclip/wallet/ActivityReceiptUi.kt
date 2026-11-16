package xyz.paperclip.wallet

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material.icons.filled.SouthWest
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp

/** A saved movement is not an independent settlement check. */
@Composable
internal fun ActivityReceiptPage(item: WalletActivity, unit: BitcoinUnit, recorded: String?,
	onShare: () -> Unit, onExplorer: (() -> Unit)?, onClose: () -> Unit,
) {
	Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
		Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
			Text("Payment receipt", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
			TextButton(onClick = onClose) { Text("Done") }
		}
		Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(bottom = 24.dp),
			verticalArrangement = Arrangement.spacedBy(16.dp)) {
			PaymentAmountHero((if (item.amount > 0) "+" else "") + unit.display(item.amount), "Balance change",
				if (item.ark) "Ark activity" else "On-chain transaction",
				if (item.amount > 0) Icons.Default.SouthWest else if (item.amount < 0) Icons.Default.NorthEast else Icons.Default.SwapHoriz)
			CardBlock("Payment details") {
				ReviewDetailRow("Status", item.status.replace('_', ' '), emphasized = true)
				ReviewDetailRow("Type", item.kind)
				recorded?.let { ReviewDetailRow("Recorded", it) }
				Text("Status reflects the last wallet update.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
				HorizontalDivider()
				Text(if (item.ark) "Movement ID" else "Transaction ID", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
				SelectionContainer { Text(item.id, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace) }
			}
			Text(if (item.ark) "An Ark balance movement does not by itself confirm that a multi-step payment reached the recipient. Check payment status before trying again."
				else if (item.status == "confirmed") "Net change to your wallet balance, including any transaction fee paid by this wallet."
				else "Confirmation has not been verified. Check Activity before sending again.",
				style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
			WalletPrimaryButton(onClick = onShare, modifier = Modifier.fillMaxWidth()) { Text("Share receipt") }
			onExplorer?.let { TextButton(onClick = it, modifier = Modifier.fillMaxWidth()) { Text("View in explorer") } }
		}
	}
}
