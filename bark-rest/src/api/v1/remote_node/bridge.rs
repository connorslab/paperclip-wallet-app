//! Bridge funding reuses the node's single-use review and durable send journal.
//! Callers hold the wallet lifecycle lock before entering these methods.
use super::*;
use bark::lightning_invoice::Bolt11Invoice;

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Terms { pub invoice: String, pub expires_at: u64 }
impl Terms {
	pub fn validate(&self, invoice: &str) -> anyhow::Result<()> {
		ensure!(self.invoice == invoice, "Funding invoice changed. Review the conversion again");
		ensure!(self.expires_at > model::now().as_secs().saturating_add(5), "Bridge quote expired. Nothing was submitted");
		Ok(())
	}
}
pub(super) fn request(operation: Operation, invoice: &str, expires_at: u64, hash: &str, fee: u64, id: &str) -> Request {
	Request { operation,bridge:Some(Terms {invoice:invoice.into(),expires_at}),connection:None,
		destination:invoice.into(),amount_sat:None,maximum_fee_sat:Some(fee),description:String::new(),
		request_id:id.into(),payment_hash:hash.into(),receive:false }
}
pub(in crate::api::v1) async fn prepare(state: &ServerState, invoice: &str, expires_at: u64, fee: u64) -> anyhow::Result<Value> {
	tokio::time::timeout(Duration::from_secs(90), async {
		let mut sessions = state.remote_node.lock().await;
		execute(state,&mut sessions,request(Operation::Prepare,invoice,expires_at,"",fee,"")).await
	}).await.context("Funding review timed out. No payment was submitted")?
}
pub(in crate::api::v1) async fn fund<F>(state: &ServerState, invoice: &str, expires_at: u64, hash: &str, fee: u64, id: &str, retain: F) -> anyhow::Result<Value>
where F: FnOnce(&str) -> anyhow::Result<()> {
	tokio::time::timeout(Duration::from_secs(180), async {
		let mut sessions = state.remote_node.lock().await;
		let (root,network) = context(state).await?;
		fund_at(root,network,&mut sessions,request(Operation::Pay,invoice,expires_at,hash,fee,id),retain).await
	}).await.context("Funding request timed out. Check this saved conversion; do not send it again")?
}
pub(super) async fn fund_at<F>(root: PathBuf, network: Network, sessions: &mut Sessions, input: Request, retain: F) -> anyhow::Result<Value>
where F: FnOnce(&str) -> anyhow::Result<()> {
	let review = sessions.reviews.get(&root).context("Review this conversion again. Nothing was submitted")?;
	check_review(review,&input,&node(&root)?)?;
	// Retain the Bridge/node binding before starting the asynchronous send.
	// The node journal remains the authoritative record of submission.
	retain(&review.node_id)?;
	execute_at(root,network,sessions,input).await
}
pub(in crate::api::v1) async fn status(state: &ServerState, invoice: &str, hash: &str, node_id: &str, fee: u64) -> anyhow::Result<Option<String>> {
	tokio::time::timeout(Duration::from_secs(45), async {
		let mut sessions = state.remote_node.lock().await;
		let (root,network) = context(state).await?;
		status_at(root,network,&mut sessions,invoice,hash,node_id,fee).await
	}).await.context("Funding status timed out. No payment was sent")?
}

pub(super) async fn status_at(root: PathBuf, network: Network, sessions: &mut Sessions, invoice: &str, hash: &str, node_id: &str, fee: u64) -> anyhow::Result<Option<String>> {
	// Absence is meaningful only under the same cross-process exclusion as
	// submission. A crashed preflight has no node intent and can be reviewed
	// again; an unknown journal entry must never be treated as absent.
	{
		let _lock = bark::lock_manager::platform_default(Some(&root),None)?;
		let path = record_path(&root,hash,false)?;
		ensure!(!path.is_symlink(), "Invalid funding storage");
		if !path.try_exists()? { return Ok(None); }
		let record: Record = load(&path)?;
		let expected: Bolt11Invoice = invoice.parse()?;
		ensure!(expected.payment_hash().to_string() == hash && expected.amount_milli_satoshis() == Some(record.amount_msat.parse()?), "Saved funding amount differs from this conversion");
		ensure!(!record.receive && record.invoice == invoice && record.payment_hash == hash && record.node_id == node_id
			&& record.maximum_fee_sat == fee, "Saved funding differs from this conversion. Check the original node payment");
	}
	let mut input = request(Operation::Status,invoice,0,hash,fee,""); input.bridge = None;
	let result = execute_at(root,network,sessions,input).await?;
	Ok(Some(result["state"].as_str().context("Funding status unavailable")?.to_owned()))
}
