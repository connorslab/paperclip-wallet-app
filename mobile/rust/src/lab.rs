//! Test-only line protocol using the exact C ABI called by Swift.
//! The fixed seed is public test data. The bridge rejects mainnet.
use std::ffi::{CStr, CString};
use std::io::{self, BufRead, Write};

fn main() {
	let seed = [42u8; 64];
	for line in io::stdin().lock().lines() {
		let request = CString::new(line.expect("test input")).expect("no NUL");
		let reply = unsafe { paperclip_mobile::paperclip_mobile_call(request.as_ptr(), seed.as_ptr()) };
		assert!(!reply.is_null());
		println!("{}", unsafe { CStr::from_ptr(reply) }.to_str().expect("JSON"));
		io::stdout().flush().unwrap();
		unsafe { paperclip_mobile::paperclip_mobile_free(reply); }
	}
}
