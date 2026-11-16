//! Explicit, reviewed outgoing conversions. Node funding is not settlement.
use super::*;

#[derive(Serialize, Deserialize)]
pub(super) struct Funding {
	pub node_id: String,
	pub maximum_fee_sat: u64,
	pub state: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Request {
	hash: String,
	maximum_fee_sat: u64,
	#[serde(default)] request_id: String,
}
pub(super) fn fundable(record: &Record, at: u64) -> anyhow::Result<Invoice> {
	ensure!(record.direction == Direction::PayBtc && !settled(record) && matches!(record.state.as_str(),"quoted" | "offered"),
		"This conversion is not available to fund. Check its saved status");
	ensure!(record.funding.as_ref().is_none_or(|v|v.state == "not_submitted") && record.ark_funding.as_ref().is_none_or(|v|v.state == "not_submitted"),
		"This conversion already has a funding request. Check its status; it will not be sent again");
	record.quote.validate(&Invoice::parse(&record.target)?,record.direction,Some(at))
}
pub(super) async fn prepare(State(state): State<Arc<ServerState>>, Json(input): Json<Request>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		let _session = state.bridge.try_lock().map_err(|_|anyhow::anyhow!("A Bridge request is already running"))?;
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let root = root(&state).await?;
		let _lock = bark::lock_manager::platform_default(Some(&root),None)?;
		let record = load(&root,&path(&root,Direction::PayBtc,&input.hash)?)?;
		let hold = fundable(&record,now())?;
		ensure!(client()?.availability(Direction::PayBtc).await?.open, "The Bridge is paused. Nothing was submitted");
		let review = remote_node::bridge::prepare(&state,&hold.text,record.quote.expires_at,input.maximum_fee_sat).await?;
		fundable(&record,now())?;
		ensure!(review["payment_hash"] == record.quote.hash && review["amount_msat"] == hold.msat.to_string(), "Funding review differs from the saved conversion");
		Ok(json!({"quote":public(&record)?,"review":review}))
	}.await)
}
pub(super) async fn fund(State(state): State<Arc<ServerState>>, Json(input): Json<Request>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		let _session = state.bridge.try_lock().map_err(|_|anyhow::anyhow!("A Bridge request is already running. Check its status shortly"))?;
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let root = root(&state).await?;
		let _lock = bark::lock_manager::platform_default(Some(&root),None)?;
		let mut record = load(&root,&path(&root,Direction::PayBtc,&input.hash)?)?;
		let hold = fundable(&record,now())?;
		// Check availability before approval is consumed. Quote lifetime and the
		// exact review are checked again after the node identity preflight.
		ensure!(client()?.availability(Direction::PayBtc).await?.open, "The Bridge is paused. Nothing was submitted");
		let result = remote_node::bridge::fund(&state,&hold.text,record.quote.expires_at,&input.hash,input.maximum_fee_sat,&input.request_id,|node_id| {
			record.ark_funding = None;
			record.funding = Some(Funding {node_id:node_id.into(),maximum_fee_sat:input.maximum_fee_sat,state:"unknown".into()});
			save(&root,&record)
		}).await?;
		let funding = record.funding.as_mut().context("Funding record unavailable. Check the original node payment")?;
		ensure!(result["node_id"] == funding.node_id && result["payment_hash"] == input.hash && result["invoice"] == hold.text
			&& result["amount_msat"] == hold.msat.to_string() && result["receive"] == false, "Funding response differs from the conversion. Check its status");
		funding.state = result["state"].as_str().unwrap_or("unknown").into();
		save(&root,&record)?;
		public(&record)
	}.await)
}
pub(super) async fn check(state: &ServerState, record: &Record) -> anyhow::Result<Option<String>> {
	let funding = record.funding.as_ref().context("No saved funding request")?;
	remote_node::bridge::status(state,&record.quote.hold_invoice,&record.quote.hash,&funding.node_id,funding.maximum_fee_sat).await
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn funding_requires_a_live_outgoing_quote_without_a_submission() {
		let mut record = super::super::tests::fixture(Direction::PayBtc);
		assert!(fundable(&record,1_000_001).is_ok());
		record.state = "offered".into(); assert!(fundable(&record,1_000_001).is_ok());
		assert!(fundable(&record,1_001_795).is_err());
		for state in ["unknown","pending","succeeded","failed"] {
			record.funding = Some(Funding {node_id:"node".into(),maximum_fee_sat:10,state:state.into()});
			assert!(fundable(&record,1_000_001).is_err());
		}
		record.funding.as_mut().unwrap().state = "not_submitted".into();
		assert!(fundable(&record,1_000_001).is_ok());
		record.verified_settlement = true; assert!(fundable(&record,1_000_001).is_err());
		record.verified_settlement = false; record.state = "unknown".into(); assert!(fundable(&record,1_000_001).is_err());
		assert!(fundable(&super::super::tests::fixture(Direction::ReceiveXbt),1_000_001).is_err());
	}
}

#[cfg(test)]
mod persistence_tests {
	use super::*;
	#[test]
	fn successful_node_funding_is_durable_but_does_not_claim_btc_settlement() {
		let root = tempfile::tempdir().unwrap();
		let mut record = super::super::tests::fixture(Direction::PayBtc);
		record.funding = Some(Funding {node_id:"02".to_owned()+&"01".repeat(32),maximum_fee_sat:10,state:"succeeded".into()});
		save(root.path(),&record).unwrap();
		let restored = records(root.path()).unwrap().remove(0);
		let value = public(&restored).unwrap();
		assert_eq!(value["funding"]["state"],"succeeded");
		assert_eq!(value["verified_settlement"],false);
		assert!(fundable(&restored,1_000_001).is_err());
		assert!(!value.to_string().contains(&record.quote.token));
		// Migration: older receive/outgoing quotes do not imply a funding attempt.
		let mut old = serde_json::to_value(super::super::tests::fixture(Direction::PayBtc)).unwrap();
		old.as_object_mut().unwrap().remove("funding");
		assert!(serde_json::from_value::<Record>(old).unwrap().funding.is_none());
	}
}
