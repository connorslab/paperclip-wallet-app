//! Serialized native XBT wallet bridge. The application explicitly enables mainnet.

mod session;

use std::ffi::{c_char, CStr, CString};
use std::sync::{Mutex, OnceLock};

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
		static STATE: OnceLock<Mutex<Option<session::Session>>> = OnceLock::new();
		let mut state = STATE.get_or_init(|| Mutex::new(None)).lock()
			.map_err(|_| anyhow::anyhow!("wallet session requires restart"))?;
		let seed = unsafe { *(seed as *const [u8; 64]) };
		session::dispatch(&mut state, request, seed)
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
