use rusqlite::Transaction;
use super::Migration;
pub struct Migration0043;
impl Migration for Migration0043 {
	fn name(&self) -> &str { "authorized on-chain sends" }
	fn to_version(&self) -> i64 { 43 }
	fn do_migration(&self, conn: &Transaction) -> anyhow::Result<()> {
		conn.execute_batch("CREATE TABLE bark_authorized_send (
			account TEXT NOT NULL,
			txid TEXT NOT NULL,
			replaces TEXT,
			record TEXT NOT NULL,
			PRIMARY KEY (account, txid),
			UNIQUE (account, replaces)
);")?;
		Ok(())
	}
}
