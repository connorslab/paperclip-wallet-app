//! Reusable offers are receive routes, not funding authorizations. Persist the
//! management key before registration and never expose it in normal responses.
use std::{io::Write, path::Path, sync::Arc};

use anyhow::{Context, ensure};
use ark::lightning::Offer;
use axum::{Json, Router, extract::{DefaultBodyLimit, State}, routing::get};
use bitcoin::{Network, blockdata::constants::ChainHash, hashes::{Hash, sha256}};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::ServerState;
use super::{Direction, client, now, private_dir, response, root};

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Binding { pub offer: String, pub direction: Direction, pub revoked: bool }
impl Binding {
	fn validate(&self) -> anyhow::Result<()> { validate_offer(&self.offer, self.direction == Direction::PayBtc, false) }
}
fn validate_offer(text: &str, xbt: bool, check_expiry: bool) -> anyhow::Result<()> {
	ensure!(text.len() <= 16384 && !text.chars().any(char::is_whitespace), "Use an amountless mainnet BOLT12 offer");
	let offer: Offer = text.parse().ok().context("Invalid BOLT12 offer")?;
	ensure!(offer.amount().is_none() && !offer.expects_quantity(), "Use an amountless offer without quantity");
	ensure!(offer.supports_chain(ChainHash::using_genesis_block(Network::Bitcoin)), "Use a mainnet offer");
	ensure!(offer.offer_features().supports_blake2b_identity() == xbt && (!xbt || offer.offer_features().requires_blake2b_identity()), "Offer belongs to a different receiving currency");
	ensure!(!check_expiry || offer.absolute_expiry().is_none_or(|expiry| expiry.as_secs() > now()), "Receiving offer expired");
	Ok(())
}
fn valid_token(token: &str) -> bool {
	token.len() == 64 && token.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) && token.bytes().any(|b| b != b'0')
}
#[derive(Serialize, Deserialize)]
struct Record {
	token: String,
	destination: Option<String>,
	xbt: Option<bool>,
	binding: Option<Binding>,
	revocation_requested: bool,
	created: u64,
}
impl Record {
	fn id(&self) -> String { sha256::Hash::hash(self.token.as_bytes()).to_string() }
	fn public(&self) -> Value {
		json!({"id":self.id(),"destination":self.destination,"receive_xbt":self.xbt,"binding":self.binding,"revocation_requested":self.revocation_requested,"created":self.created})
	}
	fn accept(&mut self, value: Binding) -> anyhow::Result<()> {
		value.validate()?;
		ensure!(self.xbt.is_none_or(|xbt| xbt == (value.direction == Direction::ReceiveXbt)), "Bridge returned a different direction");
		if let Some(old) = &self.binding {
			ensure!(old.offer == value.offer && old.direction == value.direction && (!old.revoked || value.revoked), "Bridge binding changed; keep the saved management key");
		}
		self.binding = Some(value); Ok(())
	}
}
fn path(root: &Path, id: &str) -> anyhow::Result<std::path::PathBuf> {
	ensure!(id.len() == 64 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)), "Invalid offer reference");
	Ok(root.join(format!("{id}.json")))
}
fn save(root: &Path, row: &Record) -> anyhow::Result<()> {
	let path = path(root, &row.id())?; ensure!(!path.is_symlink(), "Invalid offer storage");
	let bytes = serde_json::to_vec(row)?; ensure!(bytes.len() <= 65536, "Offer record too large");
	let mut file = tempfile::NamedTempFile::new_in(root)?;
	file.write_all(&bytes)?; file.as_file().sync_all()?; file.persist(path).map_err(|_|anyhow::anyhow!("Could not save offer; keep its management key"))?;
	std::fs::File::open(root)?.sync_all()?; Ok(())
}
fn load(root: &Path, id: &str) -> anyhow::Result<Record> {
	let file = path(root,id)?;
	ensure!(!file.is_symlink() && std::fs::metadata(&file)?.len() <= 65536, "Invalid offer storage");
	let row: Record = serde_json::from_slice(&std::fs::read(file)?).ok().context("Saved offer could not be read; restore its management key")?;
	ensure!(row.id() == id && valid_token(&row.token) && row.destination.is_some() == row.xbt.is_some(), "Invalid saved offer");
	if let Some(value) = &row.binding { value.validate()?; }
	Ok(row)
}
fn rows(root: &Path) -> anyhow::Result<Vec<Record>> {
	let mut rows = Vec::new();
	for entry in std::fs::read_dir(root)? {
		let path = entry?.path();
		if path.extension().is_some_and(|e| e == "json") {
			ensure!(rows.len() < 100, "Offer storage is full");
			rows.push(load(root,path.file_stem().and_then(|s|s.to_str()).context("Invalid offer file")?)?);
		}
	}
	rows.sort_by_key(|r| r.created); Ok(rows)
}
#[derive(Deserialize, PartialEq)]
#[serde(rename_all="snake_case")]
enum Action { Register, Restore, Lookup, Revoke, ExportKey }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request { action: Action, id: Option<String>, destination: Option<String>, receive_xbt: Option<bool>, token: Option<String> }

pub(super) fn router() -> Router<Arc<ServerState>> {
	Router::new().route("/reusable",get(list).post(update)).route("/reusable/info",get(info)).layer(DefaultBodyLimit::max(20000))
}
async fn info(State(state): State<Arc<ServerState>>) -> impl axum::response::IntoResponse {
	response(async { let _lifecycle = state.wallet_lifecycle.lock().await; root(&state).await?; client()?.reusable_info().await }.await)
}
async fn list(State(state): State<Arc<ServerState>>) -> impl axum::response::IntoResponse {
	response(async {
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let dir = root(&state).await?.join("reusable"); private_dir(&dir)?;
		Ok(json!({"offers":rows(&dir)?.iter().map(Record::public).collect::<Vec<_>>()}))
	}.await)
}
async fn update(State(state): State<Arc<ServerState>>, Json(input): Json<Request>) -> impl axum::response::IntoResponse {
	response(async {
		let _session = state.bridge.try_lock().map_err(|_|anyhow::anyhow!("A bridge request is already running"))?;
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let dir = root(&state).await?.join("reusable"); private_dir(&dir)?;
		let mut row = if let Some(id) = input.id {
			ensure!(input.destination.is_none() && input.receive_xbt.is_none() && input.token.is_none() && input.action != Action::Restore, "A saved offer cannot change destination"); load(&dir,&id)?
		} else {
			let saved = rows(&dir)?;
			let (token, destination, xbt) = if input.action == Action::Restore {
				ensure!(input.destination.is_none() && input.receive_xbt.is_none(), "Restore only accepts a management key");
				let token = input.token.context("Enter a management key")?; ensure!(valid_token(&token), "Invalid management key"); (token,None,None)
			} else {
				ensure!(input.action == Action::Register && input.token.is_none(), "Select a saved offer");
				let destination = input.destination.context("Enter a receiving offer")?; let xbt = input.receive_xbt.context("Choose a receiving currency")?;
				validate_offer(&destination,xbt,true)?;
				let token = saved.iter().find(|r| r.destination.as_ref() == Some(&destination) && r.xbt == Some(xbt) && !r.binding.as_ref().is_some_and(|v|v.revoked))
					.map(|r|r.token.clone()).unwrap_or_else(|| sha256::Hash::hash(&bitcoin::secp256k1::rand::random::<[u8;32]>()).to_string());
				(token,Some(destination),Some(xbt))
			};
			let id = sha256::Hash::hash(token.as_bytes()).to_string();
			if path(&dir,&id)?.exists() { load(&dir,&id)? } else {
				ensure!(saved.len() < 100, "Offer storage is full");
				let row = Record {token,destination,xbt,binding:None,revocation_requested:false,created:now()}; save(&dir,&row)?; row
			}
		};
		if input.action == Action::ExportKey { return Ok(json!({"token":row.token})); }
		let action = match input.action { Action::Register => "register", Action::Revoke => "revoke", _ => "lookup" };
		if input.action == Action::Revoke { row.revocation_requested = true; save(&dir,&row)?; }
		let mut body = json!({"token":row.token});
		if input.action == Action::Register {
			ensure!(!row.revocation_requested, "Check revocation status first");
			let destination = row.destination.as_ref().context("Restore this offer using lookup")?; let xbt = row.xbt.context("Missing receiving currency")?;
			validate_offer(destination,xbt,true)?; body["destination_offer"] = json!(destination); body["destination_xbt"] = json!(xbt);
		}
		let result = client()?.reusable(action,body).await?; row.accept(result)?; save(&dir,&row)?; Ok(row.public())
	}.await)
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn canonical_offer_network_and_amount_boundaries() {
		let cases: Value = serde_json::from_str(include_str!("../../../../../mobile/Tests/PaperclipMobileTests/Fixtures/bridge-reusable.json")).unwrap();
		for row in cases.as_array().unwrap() {
			assert_eq!(validate_offer(row["offer"].as_str().unwrap(),row["xbt"].as_bool().unwrap(),true).is_ok(),row["valid"].as_bool().unwrap(),"{}",row["name"]);
		}
		assert!(validate_offer(&format!("lno1{}","q".repeat(16384)),false,true).is_err());
	}
	#[test]
	fn private_journal_roundtrip_never_exports_key_in_normal_response() {
		let dir = tempfile::tempdir().unwrap();
		let row = Record {token:"ab".repeat(32),destination:None,xbt:None,binding:None,revocation_requested:true,created:1};
		save(dir.path(),&row).unwrap();
		let restored = load(dir.path(),&row.id()).unwrap();
		assert!(restored.revocation_requested); assert_eq!(restored.token,row.token);
		assert!(!restored.public().to_string().contains(&row.token));
		assert!(path(dir.path(),"../key").is_err());
		assert!(!valid_token(&"0".repeat(64))); assert!(!valid_token(&"A".repeat(64)));
	}
}

#[cfg(test)]
mod binding_tests {
	use super::*;
	#[test]
	fn direction_recipient_and_revocation_cannot_change_after_registration() {
		let fixtures: Value = serde_json::from_str(include_str!("../../../../../mobile/Tests/PaperclipMobileTests/Fixtures/bridge-reusable.json")).unwrap();
		let offer = fixtures[0]["offer"].as_str().unwrap().to_owned();
		let mut row = Record {token:"ab".repeat(32),destination:None,xbt:Some(true),binding:None,revocation_requested:true,created:1};
		let binding = Binding {offer:offer.clone(),direction:Direction::ReceiveXbt,revoked:false};
		row.accept(binding.clone()).unwrap(); assert!(row.revocation_requested);
		assert!(row.accept(Binding {offer:fixtures[1]["offer"].as_str().unwrap().into(),direction:Direction::PayBtc,revoked:false}).is_err());
		row.accept(Binding {revoked:true,..binding.clone()}).unwrap();
		assert!(row.accept(binding).is_err());
	}
	#[cfg(unix)]
	#[test]
	fn journal_refuses_symlink_and_oversized_records() {
		let root = tempfile::tempdir().unwrap(); let elsewhere = tempfile::tempdir().unwrap();
		let row = Record {token:"ab".repeat(32),destination:None,xbt:None,binding:None,revocation_requested:false,created:1};
		let target = elsewhere.path().join("secret"); std::fs::write(&target,b"untouched").unwrap();
		std::os::unix::fs::symlink(&target,path(root.path(),&row.id()).unwrap()).unwrap();
		assert!(save(root.path(),&row).is_err()); assert!(load(root.path(),&row.id()).is_err());
		assert_eq!(std::fs::read(&target).unwrap(),b"untouched");
	}
}
