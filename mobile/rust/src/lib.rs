//! Minimal native bridge proving the existing XBT wallet's key derivation on iOS.
//! No network, payment, seed import, or receive-address operation is exported yet.

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
