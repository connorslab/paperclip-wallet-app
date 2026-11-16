//! The Bridge shares the normal Ark submission journal and uncertainty gate.
use super::*;
use ark::lightning::PaymentHash;
use bark_json::cli::{LightningSendInfo, LightningSendStateKind};

fn request(id: &str, invoice: &str, total_sat: u64) -> Request {
	Request {id:id.into(),operation:"lightning/pay".into(),body:json!({"destination":invoice,"max_total_sat":total_sat,"retry_for_secs":30})}
}
pub(in crate::api::v1) async fn pay<F>(state: Arc<ServerState>, id: &str, invoice: &str, total_sat: u64, guard: F) -> anyhow::Result<Value>
where F: Fn(PaymentHash) -> anyhow::Result<()> + Send + Sync + 'static {
	// The caller already holds wallet_lifecycle. Never wait on the reversed
	// submission/lifecycle lock order used by normal browser submissions.
	let _session = state.submissions.try_lock().map_err(|_|anyhow::anyhow!("A wallet action is still running. Check saved status shortly"))?;
	let root = root(&state).await?;
	let request = request(id,invoice,total_sat);
	let action = Action::parse(&request)?;
	let body = serde_json::from_value(request.body.clone())?;
	once(&root,&request,action.references(),|receipt|async {
		let options = bark::LightningSendOptions::default().before_submit(move |hash| {
			guard(hash)?;
			receipt.started(None,Some(hash.to_string()))
		});
		let result = lightning::pay_with_options(state.clone(),body,options).await
			.map_err(|_|anyhow::anyhow!("Ark funding did not return a confirmed result"))?;
		Ok(serde_json::to_value(result.0)?)
	}).await
}
// Caller holds the submission mutex and its directory lock. An absent record
// becomes a tombstone, so a delayed dispatch with that ID can never send later.
fn checked(root: &Path, request: &Request) -> anyhow::Result<Record> {
	let record = load_or_close_unused(root,&request.id)?;
	if record.operation.is_empty() && record.state == "rejected" && !record.initiated { return Ok(record); }
	let digest = sha256::Hash::hash(&serde_json::to_vec(&json!([request.operation,request.body]))?).to_string();
	ensure!(record.operation == request.operation && record.digest == digest, "Saved Ark submission differs from this conversion");
	Ok(record)
}
fn funding_state(initiated: bool, status: &LightningSendInfo, hash: PaymentHash, invoice: &str) -> anyhow::Result<&'static str> {
	ensure!(status.payment_hash == hash && status.invoice.as_deref().is_none_or(|v|v == invoice), "Ark funding record differs from this conversion");
	if !initiated {
		ensure!(status.state == LightningSendStateKind::Unknown, "This invoice has another Ark payment. Check its original status");
		return Ok("not_submitted");
	}
	Ok(match status.state {
		LightningSendStateKind::Paid => {
			ensure!(status.preimage.is_some_and(|preimage|preimage.compute_payment_hash() == hash), "Ark funding proof is unavailable");
			"succeeded"
		},
		LightningSendStateKind::Unknown | LightningSendStateKind::Other => "unknown",
		LightningSendStateKind::RevocableHtlcs | LightningSendStateKind::RevocationStuck | LightningSendStateKind::AwaitingReimbursement => "recovery",
		_ => "pending",
	})
}
pub(in crate::api::v1) async fn status(state: &ServerState, id: &str, invoice: &str, total_sat: u64) -> anyhow::Result<String> {
	let _session = state.submissions.try_lock().map_err(|_|anyhow::anyhow!("A wallet action is still running. Check saved status shortly"))?;
	let root = root(state).await?;
	let _lock = bark::lock_manager::platform_default(Some(&root),None)?;
	let mut record = checked(&root,&request(id,invoice,total_sat))?;
	let hash = invoice.parse::<ark::lightning::Invoice>()?.payment_hash();
	let wallet = state.require_wallet().map_err(|_|anyhow::anyhow!("Unlock your wallet first"))?;
	let info = LightningSendInfo::from_state(hash,&wallet.lightning_send_state(hash).await?);
	let result = funding_state(record.initiated,&info,hash,invoice)?;
	if result == "not_submitted" || result == "succeeded" {
		record.state = if result == "not_submitted" { "rejected" } else { "recorded" }.into();
		record.result = Some(json!({"payment_hash":hash,"state":result}));
		// A conclusive check resolves this submission warning, not BTC settlement.
		record.acknowledged = true; save(&root,&record)?;
	}
	Ok(result.into())
}

#[cfg(test)]
mod tests {
	use super::*;
	#[tokio::test]
	async fn a_closed_unseen_bridge_id_cannot_be_submitted_later() {
		let root = tempfile::tempdir().unwrap(); let request = request(&"01".repeat(32),"fixture-invoice",1201);
		let record = checked(root.path(),&request).unwrap(); assert!(!record.initiated); assert_eq!(record.state,"rejected");
		assert!(once(root.path(),&request,(None,None),|_|async {panic!("closed request must not submit")}).await.is_err());
	}
	#[tokio::test]
	async fn ark_bridge_receipts_bind_total_and_invoice_across_restart() {
		let root = tempfile::tempdir().unwrap(); let request = request(&"01".repeat(32),"fixture-invoice",1201);
		assert!(once(root.path(),&request,(None,Some("02".repeat(32))),|receipt|async move {
			receipt.started(None,Some("02".repeat(32)))?; anyhow::bail!("lost response")
		}).await.is_err());
		assert!(checked(root.path(),&request).unwrap().initiated);
		for body in [json!({"destination":"other-invoice","max_total_sat":1201,"retry_for_secs":30}),json!({"destination":"fixture-invoice","max_total_sat":1202,"retry_for_secs":30})] {
			let changed = Request {id:request.id.clone(),operation:request.operation.clone(),body};
			assert!(checked(root.path(),&changed).is_err());
		}
		assert!(once(root.path(),&request,(None,None),|_|async {panic!("must not replay")}).await.is_err());
	}
	#[test]
	fn unknown_engine_state_never_proves_an_initiated_payment_was_not_sent() {
		let preimage = ark::lightning::Preimage::from_byte_array([3;32]); let hash = preimage.compute_payment_hash();
		let mut status = LightningSendInfo {payment_hash:hash,state:LightningSendStateKind::Unknown,invoice:None,preimage:None};
		assert_eq!(funding_state(false,&status,hash,"invoice").unwrap(),"not_submitted");
		assert_eq!(funding_state(true,&status,hash,"invoice").unwrap(),"unknown");
		status.state = LightningSendStateKind::Paid;
		assert!(funding_state(false,&status,hash,"invoice").is_err()); assert!(funding_state(true,&status,hash,"invoice").is_err());
		status.preimage = Some(ark::lightning::Preimage::from_byte_array([4;32])); assert!(funding_state(true,&status,hash,"invoice").is_err());
		status.preimage = Some(preimage); assert_eq!(funding_state(true,&status,hash,"invoice").unwrap(),"succeeded");
		status.state = LightningSendStateKind::RevocationStuck; status.preimage = None;
		assert_eq!(funding_state(true,&status,hash,"invoice").unwrap(),"recovery");
		status.invoice = Some("other-invoice".into()); assert!(funding_state(true,&status,hash,"invoice").is_err());
	}
}
