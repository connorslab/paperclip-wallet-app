//! Serialized native XBT wallet bridge. The application explicitly enables mainnet.

mod session;
mod hardware;

use std::ffi::{c_char, CStr, CString};
use std::sync::{mpsc, OnceLock};

struct Operation {
	request: serde_json::Value,
	seed: [u8; 64],
	reply: mpsc::Sender<anyhow::Result<serde_json::Value>>,
}

fn native_operation(request: serde_json::Value, seed: [u8; 64]) -> anyhow::Result<serde_json::Value> {
	// iOS GCD workers have roughly 512 KiB stacks. The wallet futures require
	// more in debug builds, so all session work lives on one owned Rust thread.
	static WORKER: OnceLock<Result<mpsc::SyncSender<Operation>, String>> = OnceLock::new();
	let worker = WORKER.get_or_init(|| {
		let (sender, receiver) = mpsc::sync_channel::<Operation>(8);
		std::thread::Builder::new().name("paperclip-wallet".into()).stack_size(8 * 1024 * 1024)
			.spawn(move || {
				let mut state = None;
				for operation in receiver {
					let result = session::dispatch(&mut state, operation.request, operation.seed);
					let _ = operation.reply.send(result);
				}
			}).map(|_| sender).map_err(|e| e.to_string())
	}).as_ref().map_err(|_| anyhow::anyhow!("could not start native wallet worker"))?;
	let (reply, result) = mpsc::channel();
	worker.send(Operation { request, seed, reply }).map_err(|_| anyhow::anyhow!("wallet worker stopped; restart and reconcile before retrying"))?;
	result.recv().map_err(|_| anyhow::anyhow!("wallet worker stopped; restart and reconcile before retrying"))?
}


/// Execute one operation off the UI thread. Returned JSON is owned by Rust.
/// # Safety
/// request is a NUL-terminated UTF-8 string; seed points to 64 readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn paperclip_mobile_call(request: *const c_char, seed: *const u8) -> *mut c_char {
	let result = std::panic::catch_unwind(|| -> anyhow::Result<serde_json::Value> {
		anyhow::ensure!(!request.is_null() && !seed.is_null(), "missing input");
		let text = unsafe { CStr::from_ptr(request) }.to_str()?;
		anyhow::ensure!(text.len() < 48 * 1024 * 1024, "request too large");
		let request = serde_json::from_str(text)?;
		let seed = unsafe { *(seed as *const [u8; 64]) };
		native_operation(request, seed)
	});
	let value = match result {
		Ok(Ok(value)) => serde_json::json!({"ok": value}),
		Ok(Err(err)) => serde_json::json!({"error": format!("{err:#}")}),
		Err(_) => serde_json::json!({"error": "wallet operation interrupted; restart and reconcile before retrying"}),
	};
	CString::new(value.to_string()).expect("JSON escapes NUL").into_raw()
}

/// # Safety
/// ptr must be a live result of paperclip_mobile_call, freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn paperclip_mobile_free(ptr: *mut c_char) {
	if !ptr.is_null() { drop(unsafe { CString::from_raw(ptr) }); }
}

/// Derive an ephemeral regtest wallet fingerprint. The caller owns both buffers.
/// Returns zero on success. Never logs, stores, or returns the supplied seed.
///
/// # Safety
/// `seed` must point to 64 readable bytes and `out` to 4 writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn paperclip_mobile_probe(seed: *const u8, out: *mut u8) -> i32 {
	if seed.is_null() || out.is_null() { return -1; }
	let result = std::panic::catch_unwind(|| {
		let bytes = unsafe { &*(seed as *const [u8; 64]) };
		let wallet_seed = bark::WalletSeed::new_from_seed(bitcoin::Network::Regtest, bytes);
		let fingerprint = wallet_seed.fingerprint();
		unsafe { std::ptr::copy_nonoverlapping(fingerprint.as_bytes().as_ptr(), out, 4); }
	});
	if result.is_ok() { 0 } else { -2 }
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn ffi_receive_address_runs_from_small_ios_style_stack() {
		std::thread::Builder::new().stack_size(512 * 1024).spawn(|| {
			let dir = std::env::temp_dir().join(format!("paperclip-small-stack-{}", std::process::id()));
			assert!(!dir.exists());
			let seed = [91; 64];
			let invoke = |value: serde_json::Value| {
				let request = CString::new(value.to_string()).unwrap();
				unsafe {
					let result = paperclip_mobile_call(request.as_ptr(), seed.as_ptr());
					let value: serde_json::Value = serde_json::from_slice(CStr::from_ptr(result).to_bytes()).unwrap();
					paperclip_mobile_free(result);
					assert!(value.get("error").is_none(), "{value}");
					value["ok"].clone()
				}
			};
			invoke(serde_json::json!({"op": "create", "network": "xbt-regtest", "directory": dir}));
			let first = invoke(serde_json::json!({"op": "address_onchain"}));
			assert!(first["address"].as_str().unwrap().starts_with("bcrt1"));
			let second = invoke(serde_json::json!({"op": "address_onchain"}));
			assert_ne!(first, second);
			invoke(serde_json::json!({"op": "close"}));
			std::fs::remove_dir_all(dir).unwrap();
		}).unwrap().join().unwrap();
	}
}

#[cfg(test)]
mod rpc_tor_tests;

#[cfg(test)]
mod electrum_reconnect_tests;
