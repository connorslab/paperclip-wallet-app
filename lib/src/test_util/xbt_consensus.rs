//! Test-only Knots C API oracle. This does not check chain state or mempool policy.
//! ABI: Knots v29.4.3.knots20260508, src/script/bitcoinconsensus.h (API 2).

use std::ffi::{c_int, c_uint};
use std::path::Path;
use std::sync::OnceLock;

use bitcoin::consensus::serialize;
use bitcoin::hashes::Hash;
use bitcoin::{absolute, transaction, Amount, OutPoint, ScriptBuf, Sequence, Transaction, TxIn, TxOut, Witness};
use libloading::Library;
use bitcoin::key::{TapTweak, TweakedPublicKey};
use bitcoin::secp256k1::{Keypair, Message, SecretKey};
use bitcoin_ext::unified::{self, Execution};
use crate::SECP;


#[repr(C)]
struct Utxo {
	script: *const u8,
	script_len: c_uint,
	value: i64,
}

type Verify = unsafe extern "C" fn(
	*const u8, c_uint, i64, *const u8, c_uint,
	*const Utxo, c_uint, c_uint, c_uint, *mut c_int,
) -> c_int;

const VERIFY_ALL: c_uint = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 9)
	| (1 << 10) | (1 << 11) | (1 << 17) | (1 << 22);

fn library() -> Result<&'static Library, String> {
	static LIBRARY: OnceLock<Result<Library, String>> = OnceLock::new();
	LIBRARY.get_or_init(|| {
		let path = std::env::var_os("PAPERCLIP_XBT_CONSENSUS_LIBRARY")
			.ok_or("PAPERCLIP_XBT_CONSENSUS_LIBRARY is required; no verifier fallback")?;
		if !Path::new(&path).is_absolute() {
			return Err("consensus library path must be absolute".into());
		}
		// SAFETY: this opt-in test harness loads a trusted, explicitly selected
		// native library. The pinned public C header defines these ABI types.
		let library = unsafe { Library::new(path) }.map_err(|e| e.to_string())?;
		let version = unsafe {
			library.get::<unsafe extern "C" fn() -> c_uint>(b"bitcoinconsensus_version\0")
				.map_err(|e| e.to_string())?()
		};
		if version != 2 {
			return Err(format!("expected consensus API 2, received {version}"));
		}
		Ok(library)
	}).as_ref().map_err(Clone::clone)
}

pub fn verify_tx(inputs: &[TxOut], input_idx: usize, tx: &Transaction) -> Result<(), String> {
	if inputs.len() != tx.input.len() || input_idx >= inputs.len() {
		return Err("every input requires an ordered prevout and a valid input index".into());
	}
	let narrow = |n: usize| c_uint::try_from(n).map_err(|_| "consensus input too large".to_owned());
	let spent = inputs.iter().map(|o| Ok(Utxo {
		script: o.script_pubkey.as_bytes().as_ptr(),
		script_len: narrow(o.script_pubkey.len())?,
		value: i64::try_from(o.value.to_sat()).map_err(|_| "prevout amount out of range")?,
	})).collect::<Result<Vec<_>, String>>()?;
	let bytes = serialize(tx);
	let index = narrow(input_idx)?;
	let length = narrow(bytes.len())?;
	let count = narrow(spent.len())?;
	let prevout = &spent[input_idx];
	let mut error: c_int = 0;
	// SAFETY: all pointers refer to live, immutable buffers for this synchronous
	// call. Utxo matches the C ABI; checked lengths cannot truncate. The library
	// is retained for the process lifetime, including the function pointer.
	let result = unsafe {
		let verify = library()?.get::<Verify>(b"bitcoinconsensus_verify_script_with_spent_outputs\0")
			.map_err(|e| e.to_string())?;
		verify(prevout.script, prevout.script_len, prevout.value, bytes.as_ptr(), length,
			spent.as_ptr(), count, index, VERIFY_ALL, &mut error)
	};
	if result == 1 && error == 0 { Ok(()) }
	else { Err(format!("Knots script verification rejected input {input_idx} (API error {error})")) }
}

#[test]
fn unified_signature_requires_unchanged_transaction_and_prevouts() {

	let key = Keypair::from_secret_key(&SECP, &SecretKey::from_slice(&[17; 32]).unwrap())
		.tap_tweak(&SECP, None).to_keypair();
	let mut prevouts = vec![TxOut {
		value: Amount::from_sat(10_000),
		script_pubkey: ScriptBuf::new_p2tr_tweaked(TweakedPublicKey::dangerous_assume_tweaked(key.x_only_public_key().0)),
	}];
	prevouts.push(TxOut { value: Amount::from_sat(20_000), script_pubkey: ScriptBuf::new() });
	let mut tx = Transaction {
		version: transaction::Version::TWO, lock_time: absolute::LockTime::ZERO,
		input: vec![TxIn { previous_output: OutPoint::null(), script_sig: ScriptBuf::new(),
			sequence: Sequence::MAX, witness: Witness::new() }],
		output: vec![TxOut { value: Amount::from_sat(9_000), script_pubkey: ScriptBuf::new() }],
	};
	tx.input.push(TxIn { previous_output: OutPoint { vout: 1, ..OutPoint::null() },
		script_sig: ScriptBuf::new(), sequence: Sequence::MAX, witness: Witness::new() });
	let digest = unified::digest(&tx, 0, &prevouts, unified::ALL, Execution {
		script_type: 2, script_code: None, annex: None, leaf: None,
	}).unwrap();
	let signature = SECP.sign_schnorr_no_aux_rand(&Message::from_digest(digest.to_byte_array()), &key);
	let witness = unified::signature(&signature);
	tx.input[0].witness.push(witness);
	verify_tx(&prevouts, 0, &tx).expect("Knots accepts the original XBT signature");
	let mut changed = tx.clone();
	changed.output[0].value = Amount::from_sat(8_999);
	assert!(verify_tx(&prevouts, 0, &changed).is_err());
	let mut changed_prevouts = prevouts.clone();
	changed_prevouts[0].value = Amount::from_sat(10_001);
	assert!(verify_tx(&changed_prevouts, 0, &tx).is_err());
	changed_prevouts = prevouts.clone();
	changed_prevouts[1].value = Amount::from_sat(20_001);
	assert!(verify_tx(&changed_prevouts, 0, &tx).is_err());
	changed_prevouts = prevouts.clone();
	changed_prevouts[1].script_pubkey = ScriptBuf::from_bytes(vec![0x51]);
	assert!(verify_tx(&changed_prevouts, 0, &tx).is_err());
	for offset in [0, 64] {
		let mut bad = witness;
		bad[offset] ^= 1;
		changed = tx.clone();
		changed.input[0].witness = Witness::from_slice(&[bad]);
		assert!(verify_tx(&prevouts, 0, &changed).is_err());
	}
	assert!(verify_tx(&[], 0, &tx).is_err());
	assert!(verify_tx(&prevouts, 2, &tx).is_err());
}
