//! Explicit owner assignment for pre-v2 node records. Never moves credentials,
//! changes payment outcomes, contacts a node or executes a payment.
use super::*;
use std::io::Read;

const BINDING: &str = "paperclip-owner-v2.json";
const STAGING: &str = ".node-owner-staging";
const NEEDS_REVIEW: &str = "Older Lightning records need wallet ownership verification before use. Review the older connection after backing up this host. Do not delete these records";

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Binding { version: u32, owner: String, reviewed_digest: String }
pub(super) struct Review { id: String, owner: String, root: PathBuf, digest: String, created: Instant }
struct Snapshot { digest: String, connection: Option<Value>, count: usize, unresolved: usize }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Approval { request_id: String, owner_confirmed: bool, backup_confirmed: bool }

fn absent(path: &Path) -> anyhow::Result<bool> {
	match std::fs::symlink_metadata(path) {
		Ok(_) => Ok(false),
		Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(true),
		Err(_) => anyhow::bail!("Older node storage could not be checked"),
	}
}
fn directory(path: &Path) -> anyhow::Result<()> {
	ensure!(std::fs::symlink_metadata(path).map(|m| m.is_dir()).unwrap_or(false), "{NEEDS_REVIEW}");
	Ok(())
}
fn legacy_root(base: &Path, fingerprint: Fingerprint, owner: &str) -> anyhow::Result<PathBuf> {
	directory(base)?;
	let root = base.join(fingerprint.to_string()); directory(&root)?;
	directory(&root.join("payments"))?;
	// Two histories cannot be combined safely by choosing one or overwriting it.
	ensure!(absent(&base.join(format!("v2-{owner}")))?, "Two node histories exist. Keep both backups and reconcile them before recovery");
	Ok(root)
}
pub(super) fn owned_root(base: &Path, fingerprint: Fingerprint, owner: &str) -> anyhow::Result<PathBuf> {
	let root = legacy_root(base, fingerprint, owner)?;
	let binding: Binding = serde_json::from_slice(&read_file(&root.join(BINDING)).map_err(|_| anyhow::anyhow!(NEEDS_REVIEW))?)
		.map_err(|_| anyhow::anyhow!(NEEDS_REVIEW))?;
	ensure!(binding.version == 2 && binding.owner == owner
		&& binding.reviewed_digest.parse::<sha256::Hash>().is_ok(), "Older node records are assigned to another wallet or need recovery. Keep their full backup");
	Ok(root)
}
fn read_file(path: &Path) -> anyhow::Result<Vec<u8>> {
	let metadata = std::fs::symlink_metadata(path).context("Older node record is unavailable")?;
	ensure!(metadata.is_file() && metadata.len() <= 2 * 1024 * 1024, "Older node record is linked, nonregular or too large");
	#[cfg(unix)] {
		use std::os::unix::fs::MetadataExt;
		ensure!(metadata.nlink() == 1, "Older node record must not be hard-linked");
	}
	let mut bytes = Vec::new();
	std::fs::File::open(path)?.take(2 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
	ensure!(bytes.len() <= 2 * 1024 * 1024, "Older node record is too large");
	Ok(bytes)
}
fn snapshot(root: &Path) -> anyhow::Result<Snapshot> {
	ensure!(absent(&root.join(BINDING))?, "These records already have an owner binding. Reopen the connection; do not assign them again");
	let mut files = Vec::new();
	for entry in std::fs::read_dir(root)? {
		let path = entry?.path();
		match path.file_name().and_then(|v| v.to_str()) {
			Some("LOCK" | "payments") => {},
			Some("connection.json" | "offer.json") => files.push(path),
			_ => anyhow::bail!("Unrecognized older node files need manual recovery. Keep the full backup"),
		}
	}
	for entry in std::fs::read_dir(root.join("payments"))? {
		ensure!(files.len() < 10002, "Older node history needs archival before recovery");
		files.push(entry?.path());
	}
	files.sort();
	let mut digest_bytes = Vec::new();
	let mut connection = None;
	let mut has_offer = false;
	let mut count = 0;
	let mut unresolved = 0;
	for path in files {
		let bytes = read_file(&path)?;
		ensure!(digest_bytes.len() + bytes.len() < 32 * 1024 * 1024, "Older node history is too large for one review");
		let name = path.strip_prefix(root)?.to_str().context("Invalid node record name")?;
		digest_bytes.extend_from_slice(&(name.len() as u64).to_le_bytes()); digest_bytes.extend_from_slice(name.as_bytes());
		digest_bytes.extend_from_slice(&(bytes.len() as u64).to_le_bytes()); digest_bytes.extend_from_slice(&bytes);
		if name == "connection.json" {
			let saved: Connection = serde_json::from_slice(&bytes).map_err(|_| anyhow::anyhow!("Older connection is invalid; restore its backup"))?;
			transport::endpoint(&saved.endpoint, saved.use_tor)?;
			ensure!(saved.node_id.parse::<bitcoin::secp256k1::PublicKey>().is_ok(), "Older connection has no valid node identity");
			connection = Some(public_connection(&saved));
		} else if name == "offer.json" {
			let value: Value = serde_json::from_slice(&bytes).map_err(|_| anyhow::anyhow!("Older offer is invalid; restore its backup"))?;
			ensure!(value["node_id"].as_str().is_some() && value["offer"].as_str().is_some(), "Older offer is incomplete");
			has_offer = true;
		} else {
			let record: Record = serde_json::from_slice(&bytes).map_err(|_| anyhow::anyhow!("Older payment record is invalid; restore its backup"))?;
			ensure!(record_path(root, &record.payment_hash, record.receive)? == path
				&& record.node_id.parse::<bitcoin::secp256k1::PublicKey>().is_ok()
				&& record.amount_msat.parse::<u64>().is_ok(), "Older payment identity is invalid; keep its backup");
			count += 1;
			if !record.receive && !matches!(record.state.as_str(), "succeeded" | "failed") { unresolved += 1; }
		}
	}
	ensure!((count == 0 && !has_offer) || connection.is_some(), "Older payment history has no connection. Restore the complete backup");
	Ok(Snapshot { digest:sha256::Hash::hash(&digest_bytes).to_string(), connection, count, unresolved })
}
fn prepare(scope: &StorageScope, sessions: &mut Sessions) -> anyhow::Result<Value> {
	sessions.recovery = None;
	let owner = storage_identity(scope.network, scope.mailbox);
	let root = legacy_root(&scope.base, scope.fingerprint, &owner)?;
	let _lock = bark::lock_manager::platform_default(Some(&root), None)?;
	let data = snapshot(&root)?;
	let id = sha256::Hash::hash(&bitcoin::secp256k1::rand::random::<[u8;32]>()).to_string();
	let value = json!({"request_id":id,"wallet_id":owner,"network":scope.network.to_string(),
		"connection":data.connection,"payment_count":data.count,"unresolved_sends":data.unresolved});
	sessions.recovery = Some(Review { id, owner, root, digest:data.digest, created:Instant::now() });
	Ok(value)
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum AssignmentStage { Created, Staged, Published, Durable }

fn publish_binding(file: tempfile::NamedTempFile, target: &Path) -> anyhow::Result<()> {
	#[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
	{
		// tempfile's no-clobber fallback can create a hard link before unlinking
		// its source. A crash between those steps would leave an ambiguous linked
		// owner record. Require the native atomic operation instead; unsupported
		// filesystems fail closed. Unpublished staging files are never authority.
		let (_file, source) = file.keep().map_err(|_| anyhow::anyhow!("Could not retain the staged owner record"))?;
		rustix::fs::renameat_with(rustix::fs::CWD, &source, rustix::fs::CWD, target, rustix::fs::RenameFlags::NOREPLACE)
			.map_err(|_| anyhow::anyhow!("Owner assignment could not be confirmed safely. Check the saved connection before another review and keep your complete host backup"))?;
	}
	#[cfg(target_os = "windows")]
	{
		// tempfile uses MoveFileExW without MOVEFILE_REPLACE_EXISTING here.
		// Windows private-directory and durable-directory acceptance is separate.
		file.persist_noclobber(target).map_err(|_| anyhow::anyhow!("Owner assignment was not confirmed. Check the saved connection before another review"))?;
	}
	#[cfg(not(any(target_os = "linux", target_os = "android", target_vendor = "apple", target_os = "windows")))]
	{
		let _ = (file, target);
		anyhow::bail!("Atomic node-owner assignment is not supported on this platform");
	}
	Ok(())
}

fn commit(scope: &StorageScope, sessions: &mut Sessions, input: Approval) -> anyhow::Result<Value> {
	commit_with_checkpoint(scope, sessions, input, |_| {})
}
fn commit_with_checkpoint(scope: &StorageScope, sessions: &mut Sessions, input: Approval,
	checkpoint: impl Fn(AssignmentStage),
) -> anyhow::Result<Value> {
	let review = sessions.recovery.take().context("Review the older connection first. An interrupted assignment is never retried automatically")?;
	let owner = storage_identity(scope.network, scope.mailbox);
	ensure!(input.owner_confirmed && input.backup_confirmed, "Confirm the original wallet and complete host backup first");
	ensure!(review.id == input.request_id && review.owner == owner && review.created.elapsed() < Duration::from_secs(120), "Recovery review changed or expired. Review again");
	let root = legacy_root(&scope.base, scope.fingerprint, &owner)?;
	ensure!(root == review.root, "Recovery wallet changed. Review again");
	let _lock = bark::lock_manager::platform_default(Some(&root), None)?;
	ensure!(snapshot(&root)?.digest == review.digest, "Older records changed. Review them again before assigning ownership");
	// Publish only the binding, with no-clobber semantics. All original bytes stay
	// in place, so an interrupted response cannot lose or duplicate payment history.
	let binding = Binding {version:2, owner, reviewed_digest:review.digest};
	// Outside every wallet's node-history directory. A killed writer may leave
	// an empty or partial file here; never read it as a binding or delete history
	// to unblock recovery. A fresh explicit review can stage a new candidate.
	let staging = scope.base.join(STAGING); private_dir(&staging)?;
	std::fs::File::open(&scope.base)?.sync_all()?;
	let mut file = tempfile::NamedTempFile::new_in(&staging)?;
	checkpoint(AssignmentStage::Created);
	file.write_all(&serde_json::to_vec(&binding)?)?; file.as_file().sync_all()?;
	checkpoint(AssignmentStage::Staged);
	publish_binding(file, &root.join(BINDING))?;
	checkpoint(AssignmentStage::Published);
	std::fs::File::open(&root)?.sync_all()?;
	std::fs::File::open(&staging)?.sync_all()?;
	checkpoint(AssignmentStage::Durable);
	sessions.reviews.remove(&root);
	Ok(json!({"assigned":true}))
}
pub(super) async fn review(State(state): State<Arc<ServerState>>) -> (StatusCode, HeaderMap, Json<Value>) {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let mut sessions = state.remote_node.lock().await;
	response(async { prepare(&storage_scope(&state).await?, &mut sessions) }.await)
}
pub(super) async fn assign(State(state): State<Arc<ServerState>>, Json(input): Json<Approval>) -> (StatusCode, HeaderMap, Json<Value>) {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let mut sessions = state.remote_node.lock().await;
	response(async { commit(&storage_scope(&state).await?, &mut sessions, input) }.await)
}

#[cfg(test)]
mod tests {
	use super::*;
	use super::super::storage_tests::mailbox;
	use transport::Implementation;

	fn fixture() -> (tempfile::TempDir, StorageScope, PathBuf) {
		let dir = tempfile::tempdir().unwrap();
		let scope = StorageScope {base:dir.path().into(), network:Network::Regtest, mailbox:mailbox(1), fingerprint:Fingerprint::from([1,2,3,4])};
		let root = scope.base.join(scope.fingerprint.to_string()); private_dir(&root.join("payments")).unwrap();
		let connection = Connection { implementation:Implementation::Lnd, endpoint:"https://node.example".into(),credential:"private-fixture".into(),certificate_sha256:String::new(),use_tor:false,receive_only:true,node_id:mailbox(2).to_string() };
		save(&root.join("connection.json"), &connection).unwrap();
		let record = Record {node_id:connection.node_id, payment_hash:"01".repeat(32), invoice:"saved-fixture-invoice".into(), amount_msat:"1000".into(), maximum_fee_sat:2, receive:false, state:"unknown".into()};
		save(&record_path(&root, &record.payment_hash, false).unwrap(), &record).unwrap();
		(dir, scope, root)
	}
	fn approval(review: &Value) -> Approval {
		Approval { request_id:review["request_id"].as_str().unwrap().into(), owner_confirmed:true, backup_confirmed:true }
	}
	#[test]
	fn killed_owner_assignment_preserves_records_and_allows_explicit_recovery() {
		const CHILD: &str = "PAPERCLIP_OWNER_ASSIGNMENT_TEST_CHILD";
		const CASE: &str = "PAPERCLIP_OWNER_ASSIGNMENT_TEST_STAGE";
		if let Some(base) = std::env::var_os(CHILD) {
			let scope = StorageScope {base:base.into(), network:Network::Regtest, mailbox:mailbox(1), fingerprint:Fingerprint::from([1,2,3,4])};
			let target = match std::env::var(CASE).unwrap().as_str() {
				"created" => AssignmentStage::Created, "staged" => AssignmentStage::Staged,
				"published" => AssignmentStage::Published, "durable" => AssignmentStage::Durable,
				_ => panic!("unknown assignment fixture"),
			};
			let mut sessions = Sessions::default(); let review = prepare(&scope, &mut sessions).unwrap();
			commit_with_checkpoint(&scope, &mut sessions, approval(&review), |stage| {
				if stage == target {
					std::fs::write(scope.base.join("ready"), b"boundary reached").unwrap();
					loop { std::thread::park(); }
				}
			}).unwrap();
			panic!("fixture did not stop at its boundary");
		}
		struct OwnedChild(std::process::Child);
		impl Drop for OwnedChild {
			fn drop(&mut self) { let _ = self.0.kill(); let _ = self.0.wait(); }
		}
		for stage in ["created", "staged", "published", "durable"] {
			let (_dir, scope, root) = fixture();
			let connection = std::fs::read(root.join("connection.json")).unwrap();
			let receipt = record_path(&root, &"01".repeat(32), false).unwrap();
			let original = std::fs::read(&receipt).unwrap();
			let mut child = OwnedChild(std::process::Command::new(std::env::current_exe().unwrap())
				.args(["--exact", "api::v1::remote_node::recovery::tests::killed_owner_assignment_preserves_records_and_allows_explicit_recovery"])
				.env(CHILD, &scope.base).env(CASE, stage)
				.stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn().unwrap());
			let deadline = Instant::now() + Duration::from_secs(15);
			while !scope.base.join("ready").exists() {
				assert!(child.0.try_wait().unwrap().is_none(), "{stage}: child exited before checkpoint");
				assert!(Instant::now() < deadline, "{stage}: child did not reach checkpoint");
				std::thread::sleep(Duration::from_millis(10));
			}
			child.0.kill().unwrap(); assert!(!child.0.wait().unwrap().success());
			let mut restarted = Sessions::default();
			if matches!(stage, "created" | "staged") {
				assert!(!root.join(BINDING).exists());
				let staged = std::fs::read_dir(scope.base.join(STAGING)).unwrap().map(|entry| entry.unwrap().path()).collect::<Vec<_>>();
				assert_eq!(staged.len(), 1);
				let unpublished = std::fs::read(&staged[0]).unwrap();
				assert_eq!(unpublished.is_empty(), stage == "created");
				assert!(storage_root(&scope.base, scope.network, scope.mailbox, scope.fingerprint).is_err());
				let review = prepare(&scope, &mut restarted).expect("Interrupted staging must allow a fresh explicit review");
				assert_eq!(review["unresolved_sends"], 1);
				assert!(!root.join(BINDING).exists(), "Review must not assign automatically");
				commit(&scope, &mut restarted, approval(&review)).unwrap();
				assert_eq!(std::fs::read(&staged[0]).unwrap(), unpublished, "Recovery must not adopt or delete an orphan");
			} else {
				assert!(prepare(&scope, &mut restarted).is_err(), "Published ownership cannot be reassigned");
			}
			assert_eq!(storage_root(&scope.base, scope.network, scope.mailbox, scope.fingerprint).unwrap(), root);
			assert!(storage_root(&scope.base, scope.network, mailbox(3), scope.fingerprint).is_err());
			assert_eq!(std::fs::read(receipt).unwrap(), original);
			assert_eq!(std::fs::read(root.join("connection.json")).unwrap(), connection);
			assert_eq!(records(&root).unwrap()[0].state, "unknown");
		}
	}
	#[test]
	fn binding_publication_never_replaces_an_existing_owner() {
		let dir = tempfile::tempdir().unwrap();
		let target = dir.path().join(BINDING); std::fs::write(&target, b"existing owner").unwrap();
		let mut staged = tempfile::NamedTempFile::new_in(dir.path()).unwrap();
		staged.write_all(b"another owner").unwrap(); staged.as_file().sync_all().unwrap();
		assert!(publish_binding(staged, &target).is_err());
		assert_eq!(std::fs::read(target).unwrap(), b"existing owner");
	}
	#[cfg(unix)]
	#[test]
	fn linked_staging_and_linked_publication_target_are_rejected() {
		let (_dir, scope, root) = fixture();
		let outside = tempfile::tempdir().unwrap();
		std::os::unix::fs::symlink(outside.path(), scope.base.join(STAGING)).unwrap();
		let mut sessions = Sessions::default(); let review = prepare(&scope, &mut sessions).unwrap();
		assert!(commit(&scope, &mut sessions, approval(&review)).is_err());
		assert!(!root.join(BINDING).exists());
		assert_eq!(std::fs::read_dir(outside.path()).unwrap().count(), 0);
		let target = outside.path().join("original"); std::fs::write(&target, b"keep").unwrap();
		std::os::unix::fs::symlink(&target, root.join(BINDING)).unwrap();
		let mut staged = tempfile::NamedTempFile::new_in(scope.base.as_path()).unwrap();
		staged.write_all(b"replace").unwrap();
		assert!(publish_binding(staged, &root.join(BINDING)).is_err());
		assert_eq!(std::fs::read(&target).unwrap(), b"keep");
		assert!(root.join(BINDING).is_symlink());
	}
	#[test]
	fn explicit_assignment_survives_lost_reply_without_rewriting_unknown_receipts() {
		let (_dir, scope, root) = fixture();
		let connection = std::fs::read(root.join("connection.json")).unwrap();
		let receipt = record_path(&root, &"01".repeat(32), false).unwrap();
		let original = std::fs::read(&receipt).unwrap();
		let mut sessions = Sessions::default();
		let review = prepare(&scope, &mut sessions).unwrap();
		assert_eq!(review["unresolved_sends"], 1);
		assert_eq!(review["payment_count"], 1);
		assert!(!review.to_string().contains("private-fixture"));
		assert!(!review.to_string().contains("saved-fixture-invoice"));
		assert!(storage_root(&scope.base, scope.network, scope.mailbox, scope.fingerprint).is_err());
		commit(&scope, &mut sessions, approval(&review)).unwrap();
		// Simulate losing the reply and process-local reviews. Only read back the
		// binding; retrying assignment cannot rewrite it or replay any payment.
		let mut restarted = Sessions::default();
		assert_eq!(storage_root(&scope.base, scope.network, scope.mailbox, scope.fingerprint).unwrap(), root);
		assert!(commit(&scope, &mut restarted, approval(&review)).is_err());
		assert!(prepare(&scope, &mut restarted).is_err());
		assert_eq!(std::fs::read(receipt).unwrap(), original);
		assert_eq!(std::fs::read(root.join("connection.json")).unwrap(), connection);
		assert_eq!(records(&root).unwrap()[0].state, "unknown");
		assert!(storage_root(&scope.base, scope.network, mailbox(3), scope.fingerprint).is_err());
		assert!(storage_root(&scope.base, Network::Signet, scope.mailbox, scope.fingerprint).is_err());
	}
	// Copy only test-owned regular files into a fresh location. This exercises
	// relocated storage, not a production archive format or installed host restore.
	fn copy_fixture_tree(source: &Path, destination: &Path) {
		private_dir(destination).unwrap();
		for entry in std::fs::read_dir(source).unwrap() {
			let entry = entry.unwrap(); let kind = entry.file_type().unwrap();
			let target = destination.join(entry.file_name());
			if kind.is_dir() { copy_fixture_tree(&entry.path(), &target); }
			else {
				assert!(kind.is_file(), "The fixture must not contain links or special files");
				std::fs::copy(entry.path(), target).unwrap();
			}
		}
	}
	#[test]
	fn relocated_node_records_preserve_ownership_unknowns_and_require_fresh_review() {
		for assigned in [false, true] {
			let (_source, scope, root) = fixture();
			let mut source_sessions = Sessions::default();
			let old_review = prepare(&scope, &mut source_sessions).unwrap();
			if assigned { commit(&scope, &mut source_sessions, approval(&old_review)).unwrap(); }
			let receipt = record_path(&root, &"01".repeat(32), false).unwrap();
			let credential_bytes = std::fs::read(root.join("connection.json")).unwrap();
			let receipt_bytes = std::fs::read(&receipt).unwrap();
			let binding_bytes = std::fs::read(root.join(BINDING)).ok();
			// An interrupted staging file is copied too: it is never ownership proof.
			private_dir(&scope.base.join(STAGING)).unwrap();
			std::fs::write(scope.base.join(STAGING).join("unfinished"), b"partial staged owner").unwrap();
			let destination = tempfile::tempdir().unwrap();
			let restored = StorageScope {base:destination.path().join("restored-node-data"),
				network:scope.network, mailbox:scope.mailbox, fingerprint:scope.fingerprint};
			copy_fixture_tree(&scope.base, &restored.base);
			let restored_root = restored.base.join(restored.fingerprint.to_string());
			// Neither a still-live review from another path nor an old approval in a
			// restarted process can authorize assignment of this restored copy.
			assert!(commit(&restored, &mut source_sessions, approval(&old_review)).is_err());
			let mut restarted = Sessions::default();
			assert!(commit(&restored, &mut restarted, approval(&old_review)).is_err());
			if assigned {
				assert!(prepare(&restored, &mut restarted).is_err());
				assert_eq!(std::fs::read(restored_root.join(BINDING)).ok(), binding_bytes);
			} else {
				assert!(storage_root(&restored.base, restored.network, restored.mailbox, restored.fingerprint).is_err());
				let review = prepare(&restored, &mut restarted).unwrap();
				assert_eq!(review["unresolved_sends"], 1);
				assert_eq!(review["payment_count"], 1);
				assert!(!restored_root.join(BINDING).exists());
				commit(&restored, &mut restarted, approval(&review)).unwrap();
			}
			assert_eq!(storage_root(&restored.base, restored.network, restored.mailbox, restored.fingerprint).unwrap(), restored_root);
			assert!(storage_root(&restored.base, restored.network, mailbox(3), restored.fingerprint).is_err());
			assert!(storage_root(&restored.base, Network::Signet, restored.mailbox, restored.fingerprint).is_err());
			assert_eq!(records(&restored_root).unwrap()[0].state, "unknown");
			assert_eq!(std::fs::read(restored_root.join("connection.json")).unwrap(), credential_bytes);
			assert_eq!(std::fs::read(record_path(&restored_root, &"01".repeat(32), false).unwrap()).unwrap(), receipt_bytes);
			assert_eq!(std::fs::read(restored.base.join(STAGING).join("unfinished")).unwrap(), b"partial staged owner");
			// Recovering the copy must not mutate the source snapshot.
			assert_eq!(std::fs::read(root.join(BINDING)).ok(), binding_bytes);
			assert_eq!(std::fs::read(root.join("connection.json")).unwrap(), credential_bytes);
			assert_eq!(std::fs::read(receipt).unwrap(), receipt_bytes);
		}
	}
	#[test]
	fn changed_records_wallet_review_and_missing_confirmation_cannot_assign() {
		for failure in ["records", "credential", "wallet", "expired", "token", "backup", "owner", "restart", "competing"] {
			let (_dir, mut scope, root) = fixture();
			let mut sessions = Sessions::default();
			let review = prepare(&scope, &mut sessions).unwrap();
			let mut input = approval(&review);
			match failure {
				"records" => { std::fs::write(root.join("offer.json"), br#"{"node_id":"fixture","offer":"new"}"#).unwrap(); },
				"credential" => {
					let mut saved: Connection = load(&root.join("connection.json")).unwrap();
					saved.credential = "changed-fixture".into(); save(&root.join("connection.json"), &saved).unwrap();
				},
				"wallet" => scope.mailbox = mailbox(3),
				"expired" => sessions.recovery.as_mut().unwrap().created -= Duration::from_secs(121),
				"token" => input.request_id = "00".repeat(32),
				"backup" => input.backup_confirmed = false,
				"owner" => input.owner_confirmed = false,
				"restart" => sessions = Sessions::default(),
				"competing" => { let _ = prepare(&scope, &mut sessions).unwrap(); },
				_ => unreachable!(),
			}
			assert!(commit(&scope, &mut sessions, input).is_err(), "{failure}");
			assert!(!root.join(BINDING).exists());
			assert_eq!(records(&root).unwrap()[0].state, "unknown");
		}
	}
	#[test]
	fn competing_owner_cannot_replace_a_durable_binding() {
		let (_dir, scope, root) = fixture();
		let other = StorageScope {base:scope.base.clone(), network:scope.network, mailbox:mailbox(3), fingerprint:scope.fingerprint};
		let mut first = Sessions::default(); let mut second = Sessions::default();
		let first_review = prepare(&scope, &mut first).unwrap();
		let second_review = prepare(&other, &mut second).unwrap();
		commit(&scope, &mut first, approval(&first_review)).unwrap();
		let original = std::fs::read(root.join(BINDING)).unwrap();
		assert!(commit(&other, &mut second, approval(&second_review)).is_err());
		assert_eq!(std::fs::read(root.join(BINDING)).unwrap(), original);
		assert!(storage_root(&scope.base, other.network, other.mailbox, other.fingerprint).is_err());
	}
	#[test]
	fn separate_histories_invalid_records_and_unknown_files_are_never_merged_or_skipped() {
		for failure in ["second", "bad-record", "extra-file", "missing-connection", "binding"] {
			let (_dir, scope, root) = fixture();
			match failure {
				"second" => private_dir(&scope.base.join(format!("v2-{}", storage_identity(scope.network, scope.mailbox)))).unwrap(),
				"bad-record" => std::fs::write(root.join("payments/other.json"), b"{}").unwrap(),
				"extra-file" => std::fs::write(root.join("unrecognized-backup.json"), b"{}").unwrap(),
				"missing-connection" => std::fs::remove_file(root.join("connection.json")).unwrap(),
				"binding" => std::fs::write(root.join(BINDING), b"{}").unwrap(),
				_ => unreachable!(),
			}
			assert!(prepare(&scope, &mut Sessions::default()).is_err(), "{failure}");
		}
	}
	#[cfg(unix)]
	#[test]
	fn linked_records_are_not_loaded_for_recovery() {
		for hard in [false, true] {
			let (dir, scope, root) = fixture();
			let secret = dir.path().join("outside"); std::fs::write(&secret, b"never read").unwrap();
			let path = root.join("offer.json");
			if hard { std::fs::hard_link(secret, path).unwrap(); }
			else { std::os::unix::fs::symlink(secret, path).unwrap(); }
			assert!(prepare(&scope, &mut Sessions::default()).is_err());
		}
	}
}
