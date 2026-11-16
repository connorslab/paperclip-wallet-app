//! Explicitly opted-in, read-only acceptance against the user's existing nodes.
//! No invoice creation, payment, settings update or service restart is permitted.
use super::*;

#[derive(Deserialize)]
struct Input { cases: Vec<Case> }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case { connection: InputConnection, expected_identity: String }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputConnection {
	implementation: transport::Implementation,
	endpoint: String,
	credential: String,
	#[serde(rename = "certificateSHA256")] pin: String,
	use_tor: bool,
}

#[tokio::test]
#[ignore = "Requires protected existing credentials and an explicit read-only live test opt-in"]
async fn live_startos_reads_and_rejects_wrong_pins() -> anyhow::Result<()> {
	let path = PathBuf::from(std::env::var("PAPERCLIP_LIVE_CONFIG").context("Provide a protected live-node test input")?);
	ensure!(!path.is_symlink(), "Test input must be a private regular file");
	let metadata = std::fs::metadata(&path)?;
	ensure!(metadata.is_file() && metadata.len() < 128 * 1024, "Invalid test input size");
	#[cfg(unix)] {
		use std::os::unix::fs::PermissionsExt;
		ensure!(metadata.permissions().mode() & 0o077 == 0, "Test input must not be readable by other users");
	}
	let input: Input = serde_json::from_slice(&std::fs::read(path)?)?;
	let mut checked = [false;2];
	for case in input.cases.into_iter().filter(|case| !case.connection.use_tor) {
		let c = case.connection;
		ensure!(!c.pin.is_empty(), "Verify the current node certificate fingerprints first");
		let root = tempfile::tempdir()?; private_dir(&root.path().join("payments"))?;
		let connection = Connection { implementation:c.implementation,endpoint:c.endpoint,credential:c.credential,
			certificate_sha256:c.pin,use_tor:false,receive_only:true,node_id:case.expected_identity.clone() };
		let mut sessions = Sessions::default();
		let request = serde_json::from_value(json!({"operation":"connect","connection":connection}))?;
		let public = execute_at(root.path().into(),Network::Bitcoin,&mut sessions,request).await?;
		ensure!(public["node_id"] == case.expected_identity && public.get("credential").is_none(), "Node identity or public-response validation failed");
		for _ in 0..3 {
			let request = serde_json::from_value(json!({"operation":"refresh"}))?;
			let result = execute_at(root.path().into(),Network::Bitcoin,&mut sessions,request).await?;
			ensure!(result["node_id"] == case.expected_identity && result["balance"].is_object(), "Node balance validation failed");
		}
		let mut wrong: Connection = load(&root.path().join("connection.json"))?;
		wrong.certificate_sha256 = "0".repeat(64);
		ensure!(Node::new(wrong,None)?.info().await.is_err(), "Wrong certificate pin was accepted");
		let verified = node(root.path())?;
		super::verified(&verified,Network::Bitcoin).await?;
		checked[if verified.cln() { 0 } else { 1 }] = true;
		println!("Live {} server adapter: authenticated identity, repeated balances, pin rejection and recovery passed", if verified.cln() { "CLN" } else { "LND" });
	}
	ensure!(checked == [true,true], "Supply both CLN and LND LAN cases");
	Ok(())
}
