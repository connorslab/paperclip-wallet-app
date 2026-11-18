//! Public, unfunded test key only. Never use this address for real funds.
use std::io::{self, Read};

use bitcoin::consensus::encode::{deserialize_hex, serialize_hex};
use bitcoin::hashes::Hash;
use bitcoin::key::TapTweak;
use bitcoin::secp256k1::{Keypair, Message, SecretKey};
use bitcoin::sighash::{EcdsaSighashType, Prevouts, SighashCache, TapSighashType};
use bitcoin::{absolute, transaction, Address, Amount, Network, OutPoint, ScriptBuf, Sequence, Transaction, TxIn, Witness};
use bitcoin_ext::unified::{self, Execution};
use serde_json::{json, Value};

fn main() -> Result<(), Box<dyn std::error::Error>> {
	let secp = bitcoin::secp256k1::Secp256k1::new();
	let mut request = String::new();
	io::stdin().take(1024 * 1024).read_to_string(&mut request)?;
	let request: Value = serde_json::from_str(&request)?;
	let segwit = match request["kind"].as_str() {
		Some("segwit") => true, Some("taproot") => false, _ => return Err("unknown fixture type".into()),
	};
	let base = Keypair::from_secret_key(&secp, &SecretKey::from_slice(&[17; 32])?);
	let key = base.tap_tweak(&secp, None);
	let address = if segwit {
		Address::p2wpkh(&bitcoin::CompressedPublicKey(base.public_key()), Network::Regtest)
	} else { Address::p2tr_tweaked(key.public_parts().0, Network::Regtest) };
	if request.get("funding_tx").is_none() {
		println!("{}", json!({"address":address.to_string(), "script":address.script_pubkey().to_hex_string()}));
		return Ok(());
	}
	let funding: Transaction = deserialize_hex(request["funding_tx"].as_str().ok_or("missing funding tx")?)?;
	let vout = u32::try_from(request["vout"].as_u64().ok_or("missing output index")?)?;
	let prevout = funding.output.get(vout as usize).ok_or("output index out of range")?.clone();
	if prevout.script_pubkey != address.script_pubkey() { return Err("unexpected fixture script".into()); }
	let value = prevout.value.checked_sub(Amount::from_sat(1000)).ok_or("fixture amount too small")?;
	let mut tx = Transaction {
		version: transaction::Version::TWO, lock_time: absolute::LockTime::ZERO,
		input: vec![TxIn { previous_output: OutPoint::new(funding.compute_txid(), vout),
			script_sig: ScriptBuf::new(), sequence: Sequence::MAX, witness: Witness::new() }],
		output: vec![bitcoin::TxOut { value, script_pubkey: address.script_pubkey() }],
	};
	let prevouts = [prevout];
	let script_code = ScriptBuf::new_p2pkh(&bitcoin::PublicKey::new(base.public_key()).pubkey_hash());
	let digest = unified::digest(&tx, 0, &prevouts, unified::ALL, Execution {
		script_type: if segwit { 1 } else { 2 },
		script_code: if segwit { Some(&script_code) } else { None }, annex: None, leaf: None,
	})?;
	let sign = |hash: [u8; 32]| {
		let message = Message::from_digest(hash);
		if segwit {
			let mut sig = secp.sign_ecdsa(&message, &base.secret_key()).serialize_der().to_vec();
			sig.push(unified::ALL);
			Witness::from_slice(&[sig, base.public_key().serialize().to_vec()])
		} else {
			let sig = secp.sign_schnorr_no_aux_rand(&message, &key.to_keypair());
			Witness::from_slice(&[unified::signature(&sig)])
		}
	};
	tx.input[0].witness = sign(digest.to_byte_array());
	let mut changed = tx.clone();
	changed.output[0].value = value.checked_sub(Amount::ONE_SAT).ok_or("fixture amount too small")?;
	let mut legacy = tx.clone();
	let hash = if segwit {
		SighashCache::new(&legacy).p2wpkh_signature_hash(0, &prevouts[0].script_pubkey,
			prevouts[0].value, EcdsaSighashType::All)?.to_byte_array()
	} else {
		SighashCache::new(&legacy).taproot_key_spend_signature_hash(0,
			&Prevouts::All(&prevouts), TapSighashType::All)?.to_byte_array()
	};
	legacy.input[0].witness = sign(hash);
	println!("{}", json!({"valid":serialize_hex(&tx), "changed_output":serialize_hex(&changed),
		"legacy_digest":serialize_hex(&legacy), "txid":tx.compute_txid().to_string()}));
	Ok(())
}
