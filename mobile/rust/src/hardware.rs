//! Public-only descriptor import and unified-sighash verification for QR signers.
use std::collections::BTreeMap;
use std::str::FromStr;
use bark::persist::BarkPersister;
use base64::Engine;

use anyhow::{bail, ensure, Context};
use bdk_wallet::miniscript::{Descriptor, DescriptorPublicKey, ForEachKey};
use bdk_wallet::miniscript::descriptor::DescriptorType;
use bitcoin::{Network, Psbt, ScriptBuf, Transaction, TxOut, Witness, VarInt};
use bitcoin::consensus::{deserialize, Decodable, Encodable};
use bitcoin::secp256k1::{self, Secp256k1};
use bitcoin_ext::unified::{self, Execution};

pub const MAX_TRANSFER: usize = 160 * 1024;

pub fn descriptors(value: &str, script: &str, origin: &str, network: Network, hardware: bool) -> anyhow::Result<(String, String)> {
	ensure!(value.len() <= 4096 && !value.chars().any(char::is_whitespace), "Paste one public account key or single-key descriptor");
	let value = if value.contains('(') { value.to_owned() } else {
		let (origin, value) = if let Some(expression) = value.strip_prefix('[') {
			let (embedded, key) = expression.split_once(']').context("invalid key origin")?;
			ensure!(origin.is_empty() || origin == embedded, "conflicting key origins");
			(embedded, key)
		} else { (origin, value) };
		let key = {
			// SLIP-132 key versions change address hints, not BIP32 key material.
			let mut bytes = bitcoin::base58::decode_check(value).context("invalid extended public key")?;
			ensure!(bytes.len() == 78, "invalid extended public key length");
			let version = u32::from_be_bytes(bytes[..4].try_into()?);
			let (mainnet, hint) = match version {
				0x0488b21e => (true, None), 0x043587cf => (false, None),
				0x049d7cb2 => (true, Some("nested")), 0x044a5262 => (false, Some("nested")),
				0x04b24746 => (true, Some("segwit")), 0x045f1cf6 => (false, Some("segwit")),
				_ => bail!("Import an account XPUB, YPUB, or ZPUB; private keys are not accepted"),
			};
			ensure!(mainnet == (network == Network::Bitcoin), "public key network does not match this wallet");
			if let Some(hint) = hint { ensure!(script == hint, "public key prefix does not match the chosen address type"); }
			bytes[..4].copy_from_slice(&(if mainnet { 0x0488b21eu32 } else { 0x043587cfu32 }).to_be_bytes());
			let key = bitcoin::bip32::Xpub::from_str(&bitcoin::base58::encode_check(&bytes))?;
			ensure!(key.depth == 3, "Import an account-level public key at depth 3");
			if origin.is_empty() { key.to_string() } else { format!("[{origin}]{key}") }
		};
		let expression = format!("{key}/<0;1>/*");
		match script {
			"taproot" => format!("tr({expression})"),
			"segwit" => format!("wpkh({expression})"),
			"nested" => format!("sh(wpkh({expression}))"),
			"legacy" => format!("pkh({expression})"),
			_ => bail!("Choose an address type"),
		}
	};
	let desc = Descriptor::<DescriptorPublicKey>::from_str(&value).context("invalid public descriptor")?;
	ensure!(matches!(desc.desc_type(), DescriptorType::Tr | DescriptorType::Wpkh | DescriptorType::ShWpkh | DescriptorType::Pkh), "Only single-key Taproot, native SegWit, nested SegWit, and legacy descriptors are supported");
	let mut count = 0;
	ensure!(desc.for_each_key(|key| {
		count += 1;
		match key {
			DescriptorPublicKey::XPub(x) => {
				x.wildcard == bdk_wallet::miniscript::descriptor::Wildcard::Unhardened && x.derivation_path.into_iter().all(|child| !child.is_hardened()) && x.xkey.network == network.into() && (!hardware || x.origin.as_ref().is_some_and(|(fp, path)| *fp != bitcoin::bip32::Fingerprint::default() && path.len() == x.xkey.depth as usize))
			},
			DescriptorPublicKey::MultiXPub(x) => {
				x.wildcard == bdk_wallet::miniscript::descriptor::Wildcard::Unhardened && x.derivation_paths.paths().iter().all(|path| path.into_iter().all(|child| !child.is_hardened())) && x.xkey.network == network.into() && (!hardware || x.origin.as_ref().is_some_and(|(fp, path)| *fp != bitcoin::bip32::Fingerprint::default() && path.len() == x.xkey.depth as usize))
			},
			_ => false,
		}
	}) && count == 1 && desc.has_wildcard(), "Use a single account public key; QR signing also requires its master fingerprint and full account path");
	let branches = desc.into_single_descriptors()?;
	let (receive, change) = match branches.as_slice() {
		[a, b] => (a.to_string(), b.to_string()),
		[a] => {
			let a = a.to_string();
			let a = a.split('#').next().unwrap();
			ensure!(a.contains("/0/*"), "Descriptor must contain /<0;1>/* or the receive branch /0/*");
			(a.to_owned(), a.replace("/0/*", "/1/*"))
		},
		_ => bail!("Exactly two receive/change branches are required"),
	};
	ensure!(receive != change, "receive and change descriptors must differ");
	// Reject script trees and unconventional branch layouts even when they contain one key.
	for (index, value) in [&receive, &change].iter().enumerate() {
		let body = value.split('#').next().unwrap();
		ensure!(body.contains(&format!("/{index}/*")) && !body.contains('{') && !body.contains(','), "Use standard /0/* receive and /1/* change branches without script trees");
	}
	Ok((receive, change))
}

pub fn prepare(psbt: &mut Psbt) -> anyhow::Result<()> {
	ensure!(!psbt.inputs.is_empty() && !psbt.unsigned_tx.output.is_empty(), "empty signing request");
	let previous = prevouts(psbt)?;
	for (input, previous) in psbt.inputs.iter_mut().zip(previous) {
		if previous.script_pubkey.is_p2pkh() {
			ensure!(input.non_witness_utxo.is_some(), "Legacy QR signing requires the complete previous transaction");
			// Krux deliberately rejects witness-only legacy inputs (CVE-2020-14199).
			input.witness_utxo = None;
		}
		ensure!(input.partial_sigs.is_empty() && input.tap_key_sig.is_none(), "request already contains signatures");
		ensure!(input.final_script_sig.is_none() && input.final_script_witness.is_none(), "request must be unsigned");
		input.sighash_type = Some(bitcoin::psbt::PsbtSighashType::from_u32(unified::ALL.into()));
	}
	Ok(())
}

fn prevouts(psbt: &Psbt) -> anyhow::Result<Vec<TxOut>> {
	ensure!(psbt.inputs.len() == psbt.unsigned_tx.input.len(), "input count mismatch");
	psbt.inputs.iter().zip(&psbt.unsigned_tx.input).map(|(input, vin)| {
		let full = if let Some(tx) = &input.non_witness_utxo {
			ensure!(tx.compute_txid() == vin.previous_output.txid, "previous transaction mismatch");
			Some(tx.output.get(vin.previous_output.vout as usize).context("previous output missing")?.clone())
		} else { None };
		if let (Some(a), Some(b)) = (&full, &input.witness_utxo) { ensure!(a == b, "previous output mismatch"); }
		full.or(input.witness_utxo.clone()).context("previous output missing")
	}).collect()
}

// rust-bitcoin's typed signature parsers reject 0x21. Read signatures as bytes,
// strip only signature records, then use its strict PSBT parser for everything else.
fn map(data: &mut &[u8]) -> anyhow::Result<Vec<(Vec<u8>, Vec<u8>)>> {
	let mut pairs = Vec::new(); let mut seen = std::collections::HashSet::new();
	loop {
		let length = VarInt::consensus_decode(data)?.0 as usize;
		if length == 0 { return Ok(pairs); }
		ensure!(length <= data.len(), "truncated PSBT key");
		let key = data[..length].to_vec(); *data = &data[length..];
		ensure!(seen.insert(key.clone()), "duplicate PSBT key");
		let length = VarInt::consensus_decode(data)?.0 as usize;
		ensure!(length <= data.len(), "truncated PSBT value");
		let value = data[..length].to_vec(); *data = &data[length..];
		pairs.push((key, value));
	}
}
fn write_map(pairs: &[(Vec<u8>, Vec<u8>)], out: &mut Vec<u8>) {
	for (key, value) in pairs {
		VarInt(key.len() as u64).consensus_encode(out).unwrap(); out.extend(key);
		VarInt(value.len() as u64).consensus_encode(out).unwrap(); out.extend(value);
	}
	out.push(0);
}

pub fn signed_transaction(original: &Psbt, data: &[u8]) -> anyhow::Result<Transaction> {
	ensure!(data.len() <= MAX_TRANSFER, "signed request is too large");
	let mut tx = if data.starts_with(b"psbt\xff") {
		let mut cursor = &data[5..]; let global = map(&mut cursor)?;
		let mut cleaned = b"psbt\xff".to_vec(); write_map(&global, &mut cleaned);
		let mut signatures = Vec::new();
		for _ in &original.inputs {
			let pairs = map(&mut cursor)?;
			let mut raw = BTreeMap::new(); let mut keep = Vec::new();
			for (key, value) in pairs {
				if key[0] == 2 || key[0] == 0x13 { raw.insert(key, value); }
				else { keep.push((key, value)); }
			}
			write_map(&keep, &mut cleaned); signatures.push(raw);
		}
		for _ in &original.outputs { write_map(&map(&mut cursor)?, &mut cleaned); }
		ensure!(cursor.is_empty(), "unexpected PSBT records");
		let returned = Psbt::deserialize(&cleaned)?;
		ensure!(returned.unsigned_tx == original.unsigned_tx, "signed transaction differs from the reviewed request");
		let mut tx = original.unsigned_tx.clone();
		let previous = prevouts(original)?;
		for (i, input) in returned.inputs.iter().enumerate() {
			if let Some(s) = input.sighash_type { ensure!(s.to_u32() == u32::from(unified::ALL), "signer changed unified sighash"); }
			if let Some(out) = &input.witness_utxo { ensure!(out == &previous[i], "signer changed previous output"); }
			if let Some(parent) = &input.non_witness_utxo {
				ensure!(parent.compute_txid() == tx.input[i].previous_output.txid && parent.output.get(tx.input[i].previous_output.vout as usize) == Some(&previous[i]), "signer changed previous transaction");
			}
			ensure!(input.tap_script_sigs.is_empty() && input.tap_scripts.is_empty(), "script-path signatures are unsupported");
			if input.final_script_sig.is_some() || input.final_script_witness.is_some() {
				// Krux retains the Taproot key signature alongside the final witness.
				// Accept only an exact duplicate, never conflicting signing material.
				if !signatures[i].is_empty() {
					let witness = input.final_script_witness.as_ref().context("conflicting final and partial signatures")?;
					ensure!(previous[i].script_pubkey.is_p2tr() && signatures[i].len() == 1 && witness.len() == 1
						&& signatures[i].get(&vec![0x13]).map(Vec::as_slice) == witness.iter().next(), "conflicting final and partial signatures");
				}
				tx.input[i].script_sig = input.final_script_sig.clone().unwrap_or_default();
				tx.input[i].witness = input.final_script_witness.clone().unwrap_or_default();
			} else if previous[i].script_pubkey.is_p2tr() {
				ensure!(signatures[i].len() == 1, "missing or excess signatures");
				let signature = signatures[i].get(&vec![0x13]).context("missing Taproot signature")?;
				tx.input[i].witness = Witness::from_slice(&[signature]);
			} else {
				ensure!(signatures[i].len() == 1, "missing or excess signatures");
				let (key, signature) = signatures[i].iter().next().unwrap();
				ensure!(key.len() == 34 && key[0] == 2, "invalid signing public key");
				let public = bitcoin::PublicKey::from_slice(&key[1..])?;
				if previous[i].script_pubkey.is_p2pkh() {
					tx.input[i].script_sig = pushes(&[signature, &public.to_bytes()])?;
				} else {
					tx.input[i].witness = Witness::from_slice(&[signature.as_slice(), &public.to_bytes()]);
					if let Some(redeem) = &original.inputs[i].redeem_script { tx.input[i].script_sig = pushes(&[redeem.as_bytes()])?; }
				}
			}
		}
		tx
	} else { deserialize(data).context("Scan a signed PSBT or transaction")? };
	let signatures = tx.input.iter().map(|input| (input.script_sig.clone(), input.witness.clone())).collect::<Vec<_>>();
	for input in &mut tx.input { input.script_sig = ScriptBuf::new(); input.witness = Witness::new(); }
	ensure!(tx == original.unsigned_tx, "signed transaction differs from the reviewed request");
	let previous = prevouts(original)?; let secp = Secp256k1::verification_only();
	for (i, (script_sig, witness)) in signatures.into_iter().enumerate() {
		ensure!(original.inputs[i].sighash_type.map(|s| s.to_u32()) == Some(unified::ALL.into()), "request lacks unified sighash");
		let spk = &previous[i].script_pubkey;
		if spk.is_p2tr() {
			ensure!(script_sig.is_empty() && witness.len() == 1, "unsupported Taproot witness");
			let signature = witness.iter().next().unwrap();
			ensure!(signature.len() == 65 && signature[64] == unified::ALL, "hardware wallet must sign with unified SIGHASH_ALL (0x21)");
			let key = secp256k1::XOnlyPublicKey::from_slice(&spk.as_bytes()[2..])?;
			let hash = unified::digest(&tx, i, &previous, unified::ALL, Execution { script_type: 2, script_code: None, annex: None, leaf: None })?;
			secp.verify_schnorr(&secp256k1::schnorr::Signature::from_slice(&signature[..64])?, &hash.into(), &key).context("invalid unified signature")?;
		} else {
			let legacy = spk.is_p2pkh();
			let elements = if legacy { script_pushes(&script_sig)? } else { witness.iter().map(|v| v.to_vec()).collect() };
			ensure!(elements.len() == 2 && (!legacy || witness.is_empty()), "unsupported signature stack");
			let signature = &elements[0]; let key = bitcoin::PublicKey::from_slice(&elements[1])?;
			ensure!(key.compressed && signature.last() == Some(&unified::ALL), "hardware wallet must sign with unified SIGHASH_ALL (0x21)");
			let code = ScriptBuf::new_p2pkh(&key.pubkey_hash());
			if legacy { ensure!(*spk == code, "signing key mismatch"); }
			else {
				let redeem = ScriptBuf::new_p2wpkh(&key.wpubkey_hash()?);
				if spk.is_p2sh() { ensure!(*spk == redeem.to_p2sh() && script_sig == pushes(&[redeem.as_bytes()])?, "nested SegWit key mismatch"); }
				else { ensure!(*spk == redeem && script_sig.is_empty(), "SegWit key mismatch"); }
			}
			let hash = unified::digest(&tx, i, &previous, unified::ALL, Execution { script_type: if legacy { 0 } else { 1 }, script_code: Some(&code), annex: None, leaf: None })?;
			let parsed = secp256k1::ecdsa::Signature::from_der(&signature[..signature.len()-1])?;
			let mut normal = parsed; normal.normalize_s(); ensure!(normal == parsed, "noncanonical high-S signature");
			secp.verify_ecdsa(&hash.into(), &parsed, &key.inner).context("invalid unified signature")?;
		}
		tx.input[i].script_sig = script_sig; tx.input[i].witness = witness;
	}
	Ok(tx)
}
fn pushes(parts: &[&[u8]]) -> anyhow::Result<ScriptBuf> {
	let mut builder = bitcoin::script::Builder::new();
	for part in parts { builder = builder.push_slice(bitcoin::script::PushBytesBuf::try_from(part.to_vec())?); }
	Ok(builder.into_script())
}
fn script_pushes(script: &ScriptBuf) -> anyhow::Result<Vec<Vec<u8>>> {
	script.instructions_minimal().map(|instruction| match instruction? {
		bitcoin::script::Instruction::PushBytes(bytes) => Ok(bytes.as_bytes().to_vec()),
		_ => bail!("unexpected signature opcode"),
	}).collect()
}

/// Keep the funding wallet's database lock while an Ark QR request is pending.
/// Ark keys and recovery state remain in the selected mobile wallet.
pub struct PublicFundingWallet {
	pub onchain: std::sync::Arc<tokio::sync::RwLock<bark::onchain::OnchainWallet>>,
	_lock: Box<dyn bark::lock_manager::LockManager>,
}

pub async fn open_funding_wallet(request: &serde_json::Value, network: Network) -> anyhow::Result<PublicFundingWallet> {
	let directory = std::path::PathBuf::from(request["directory"].as_str().context("funding wallet directory required")?);
	ensure!(directory.is_absolute() && directory.join("db.sqlite").is_file(), "funding wallet database missing");
	let descriptor = request["descriptor"].as_str().context("funding descriptor required")?;
	let (receive, change) = descriptors(descriptor, "segwit", "", network, true)?;
	let marker: serde_json::Value = serde_json::from_slice(&std::fs::read(directory.join("public-wallet.json"))?)?;
	ensure!(marker == serde_json::json!({"kind": "hardware", "receive": receive, "change": change}), "funding wallet descriptor mismatch");
	let identity = base64::engine::general_purpose::STANDARD.decode(request["identity"].as_str().context("funding wallet identity required")?)?;
	let identity: [u8; 64] = identity.try_into().map_err(|_| anyhow::anyhow!("invalid funding wallet identity"))?;
	let seed = bark::WalletSeed::new_from_seed(network, &identity);
	let lock = bark::lock_manager::platform_default(Some(&directory), Some(seed.fingerprint()))?;
	let db = std::sync::Arc::new(bark::persist::sqlite::SqliteClient::open(directory.join("db.sqlite"))?);
	let properties = db.read_properties().await?.context("funding wallet not initialized")?;
	ensure!(properties.network == network && properties.fingerprint == seed.fingerprint(), "funding wallet identity or network mismatch");
	let onchain = bark::onchain::OnchainWallet::load_or_create_public(network, &receive, &change, db.clone()).await?;
	Ok(PublicFundingWallet { onchain: std::sync::Arc::new(tokio::sync::RwLock::new(onchain)), _lock: lock })
}

pub fn prepare_board(psbt: &mut Psbt) -> anyhow::Result<()> {
	ensure!(prevouts(psbt)?.iter().all(|out| out.script_pubkey.is_p2wpkh() || out.script_pubkey.is_p2tr()),
		"Ark QR boarding requires a native SegWit (BIP84) or Taproot (BIP86) account so its funding transaction ID stays stable");
	prepare(psbt)
}

pub fn finalized_board(original: &Psbt, signed: &[u8]) -> anyhow::Result<Psbt> {
	let mut original = original.clone();
	prepare_board(&mut original)?;
	let tx = signed_transaction(&original, signed)?;
	ensure!(tx.compute_txid() == original.unsigned_tx.compute_txid(), "Ark funding transaction ID changed");
	for (input, signed) in original.inputs.iter_mut().zip(tx.input) {
		input.final_script_witness = Some(signed.witness);
		input.final_script_sig = None;
	}
	Ok(original)
}

#[cfg(test)]
mod tests {
	use super::*;
	use base64::{Engine, engine::general_purpose::STANDARD};

	fn fixtures() -> Vec<serde_json::Value> {
		serde_json::from_str(include_str!("../../Tests/PaperclipMobileTests/Fixtures/seedsigner.json")).unwrap()
	}

	#[test]
	fn hardware_signatures_verify_for_all_single_key_scripts() {
		let krux: Vec<serde_json::Value> = serde_json::from_str(include_str!("../../Tests/PaperclipMobileTests/Fixtures/krux.json")).unwrap();
		for fixture in fixtures().into_iter().chain(krux) {
			let mut original = Psbt::deserialize(&STANDARD.decode(fixture["original"].as_str().unwrap()).unwrap()).unwrap();
			prepare(&mut original).unwrap();
			let signed = STANDARD.decode(fixture["signed"].as_str().unwrap()).unwrap();
			let tx = signed_transaction(&original, &signed).unwrap();
			assert_eq!(signed_transaction(&original, &bitcoin::consensus::serialize(&tx)).unwrap(), tx);
			let (receive, _) = descriptors(fixture["public_key"].as_str().unwrap(), fixture["script"].as_str().unwrap(), "", Network::Bitcoin, true).unwrap();
			let descriptor = Descriptor::<DescriptorPublicKey>::from_str(&receive).unwrap();
			assert_eq!(descriptor.at_derivation_index(0).unwrap().address(Network::Bitcoin).unwrap().to_string(), fixture["receive_address"]);

			let mut changed = original.clone();
			changed.unsigned_tx.output[0].value = bitcoin::Amount::from_sat(1);
			assert!(signed_transaction(&changed, &signed).is_err(), "changed recipient amount");
			let mut changed = original.clone();
			changed.inputs[0].sighash_type = Some(bitcoin::psbt::PsbtSighashType::from_u32(1));
			assert!(signed_transaction(&changed, &signed).is_err(), "downgraded request");
			let mut changed = tx.clone();
			if changed.input[0].witness.is_empty() {
				let mut elements = script_pushes(&changed.input[0].script_sig).unwrap();
				*elements[0].last_mut().unwrap() = 1;
				changed.input[0].script_sig = pushes(&[&elements[0], &elements[1]]).unwrap();
			} else {
				let mut elements = changed.input[0].witness.to_vec();
				*elements[0].last_mut().unwrap() = 1;
				changed.input[0].witness = Witness::from_slice(&elements);
			}
			assert!(signed_transaction(&original, &bitcoin::consensus::serialize(&changed)).is_err(), "downgraded signature");
			let mut corrupt = tx.clone();
			if !corrupt.input[0].witness.is_empty() {
				let mut elements = corrupt.input[0].witness.to_vec();
				elements[0][20] ^= 1;
				corrupt.input[0].witness = Witness::from_slice(&elements);
				assert!(signed_transaction(&original, &bitcoin::consensus::serialize(&corrupt)).is_err(), "invalid signature with correct 0x21 tag");
			}

			let mut changed = tx.clone(); changed.input[0].sequence = bitcoin::Sequence::ZERO;
			assert!(signed_transaction(&original, &bitcoin::consensus::serialize(&changed)).is_err(), "changed sequence");
			assert!(signed_transaction(&original, &vec![0; MAX_TRANSFER + 1]).is_err());
		}
	}

	#[test]
	fn seedsigner_signs_bdk_requests_with_change() {
		let fixtures: Vec<serde_json::Value> = serde_json::from_str(include_str!("../../Tests/PaperclipMobileTests/Fixtures/bdk-seedsigner.json")).unwrap();
		for fixture in fixtures {
			let original = Psbt::deserialize(&STANDARD.decode(fixture["original"].as_str().unwrap()).unwrap()).unwrap();
			let signed = STANDARD.decode(fixture["signed"].as_str().unwrap()).unwrap();
			let tx = signed_transaction(&original, &signed).unwrap();
			assert_eq!(tx.output.len(), 2, "recipient plus change");
			assert!(original.fee().unwrap() >= bitcoin::FeeRate::from_sat_per_vb(2).unwrap() * tx.weight());
		}
	}

	#[test]
	fn bdk_prepares_complete_hardware_requests_and_identifies_change() {
		let mut requests = Vec::new();
		for fixture in fixtures() {
			let (receive, change) = descriptors(fixture["public_key"].as_str().unwrap(), fixture["script"].as_str().unwrap(), "", Network::Bitcoin, true).unwrap();
			let mut wallet = bdk_wallet::Wallet::create(receive, change).network(Network::Bitcoin).create_wallet_no_persist().unwrap();
			wallet.reveal_next_address(bdk_wallet::KeychainKind::External);
			let original = Psbt::deserialize(&STANDARD.decode(fixture["original"].as_str().unwrap()).unwrap()).unwrap();
			let parent = original.inputs[0].non_witness_utxo.clone().unwrap();
			wallet.apply_unconfirmed_txs([(parent, 1)]);
			let mut builder = wallet.build_tx();
			builder.add_recipient(original.unsigned_tx.output[0].script_pubkey.clone(), bitcoin::Amount::from_sat(70000));
			builder.fee_rate(bitcoin::FeeRate::from_sat_per_vb(2).unwrap());
			let mut psbt = builder.finish().unwrap();
			prepare(&mut psbt).unwrap();
			assert!(psbt.inputs.iter().all(|input| input.sighash_type.unwrap().to_u32() == 0x21));
			assert!(psbt.inputs.iter().all(|input| !input.bip32_derivation.is_empty() || !input.tap_key_origins.is_empty()));
			assert!(psbt.outputs.iter().any(|output| !output.bip32_derivation.is_empty() || !output.tap_key_origins.is_empty()), "change must identify its derivation to the signer");
			requests.push(serde_json::json!({"script": fixture["script"], "original": STANDARD.encode(psbt.serialize())}));
		}
		// Explicit opt-in exports only public test-key requests for the independent signer harness.
		if let Ok(path) = std::env::var("PAPERCLIP_HARDWARE_FIXTURES") {
			std::fs::write(path, serde_json::to_vec_pretty(&requests).unwrap()).unwrap();
		}
	}

	#[test]
	fn ark_finalization_requires_stable_txid_and_verified_unified_signatures() {
		let fixtures: Vec<serde_json::Value> = serde_json::from_str(include_str!("../../Tests/PaperclipMobileTests/Fixtures/bdk-seedsigner.json")).unwrap();
		for fixture in fixtures {
			let original = Psbt::deserialize(&STANDARD.decode(fixture["original"].as_str().unwrap()).unwrap()).unwrap();
			let signed = STANDARD.decode(fixture["signed"].as_str().unwrap()).unwrap();
			if fixture["script"] == "legacy" || fixture["script"] == "nested" {
				assert!(finalized_board(&original, &signed).unwrap_err().to_string().contains("native SegWit"));
				continue;
			}
			let proposal = finalized_board(&original, &signed).unwrap();
			let transaction = proposal.clone().extract_tx().unwrap();
			assert_eq!(transaction.compute_txid(), original.unsigned_tx.compute_txid());
			assert_eq!(proposal.fee().unwrap(), original.fee().unwrap());
			assert!(transaction.input.iter().all(|input| input.script_sig.is_empty() && !input.witness.is_empty()));
			// The durable board checkpoint serializes this PSBT; unknown sighash bytes
			// must survive through final witnesses without typed-signature decoding.
			let restored = Psbt::deserialize(&proposal.serialize()).unwrap();
			assert_eq!(restored.extract_tx().unwrap(), transaction);
			let mut changed = original.clone(); changed.unsigned_tx.output[0].value = bitcoin::Amount::from_sat(1);
			assert!(finalized_board(&changed, &signed).is_err());
		}
	}

	#[test]
	fn account_import_checks_network_origin_and_slip132_hints() {
		let fixture = &fixtures()[2];
		let value = fixture["public_key"].as_str().unwrap();
		let (origin, key) = value.split_once(']').unwrap();
		let mut bytes = bitcoin::base58::decode_check(key).unwrap();
		bytes[..4].copy_from_slice(&0x04b24746u32.to_be_bytes());
		let zpub = format!("{origin}]{}", bitcoin::base58::encode_check(&bytes));
		assert_eq!(descriptors(&zpub, "segwit", "", Network::Bitcoin, true).unwrap(), descriptors(value, "segwit", "", Network::Bitcoin, true).unwrap());
		assert!(descriptors(&zpub, "taproot", "", Network::Bitcoin, true).is_err());
		assert!(descriptors(value, "segwit", "", Network::Regtest, true).is_err());
		assert!(descriptors(key, "segwit", "", Network::Bitcoin, true).is_err());
		assert!(descriptors(key, "segwit", "", Network::Bitcoin, false).is_ok());
		assert!(descriptors(value, "segwit", "bad/origin", Network::Bitcoin, true).is_err());
	}
}
