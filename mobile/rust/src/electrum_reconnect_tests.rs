use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
use std::time::Duration;
use bdk_electrum::electrum_client::ElectrumApi;
use serde_json::{json, Value};

#[test]
fn electrum_recovers_closed_socket_without_replaying_operation() {
	let listener = TcpListener::bind("127.0.0.1:0").unwrap();
	let endpoint = format!("tcp://{}", listener.local_addr().unwrap());
	let broadcasts = Arc::new(AtomicUsize::new(0));
	let count = broadcasts.clone();
	let server = std::thread::spawn(move || {
		for connection in 0..3 {
			let (mut stream, _) = listener.accept().unwrap();
			stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
			let mut reader = BufReader::new(stream.try_clone().unwrap());
			loop {
				let mut line = String::new();
				if reader.read_line(&mut line).unwrap() == 0 { break; }
				let request: Value = serde_json::from_str(&line).unwrap();
				let method = request["method"].as_str().unwrap();
				if method == "server.ping" && connection == 0 { break; }
				if method == "blockchain.transaction.broadcast" {
					count.fetch_add(1, Ordering::SeqCst);
					break; // Response lost: client must not replay the write.
				}
				let result = match method {
					"server.version" => json!(["test", "1.4"]),
					"blockchain.block.header" => json!(bitcoin::consensus::encode::serialize_hex(&bitcoin::constants::genesis_block(bitcoin::Network::Bitcoin).header)),
					"blockchain.headers.subscribe" => json!({"height": 975000, "hex": "00".repeat(164)}),
					"server.ping" => Value::Null,
					_ => panic!("unexpected method {method}"),
				};
				writeln!(stream, "{}", json!({"id":request["id"], "result":result})).unwrap();
				if connection == 2 && method == "server.ping" { break; }
			}
		}
	});
	let runtime = tokio::runtime::Runtime::new().unwrap();
	runtime.block_on(async {
		let client = bark::electrum::Electrum::connect(endpoint, None, None, bitcoin::Network::Bitcoin).await.unwrap();
		// The preflight detects the closed first connection, then executes once.
		assert!(client.run(|c| Ok(c.inner.raw_call("blockchain.transaction.broadcast", Vec::<bdk_electrum::electrum_client::Param>::new())?)).await.is_err());
		assert_eq!(broadcasts.load(Ordering::SeqCst), 1);
		client.run(|c| Ok(c.inner.ping()?)).await.unwrap();
	});
	server.join().unwrap();
	assert_eq!(broadcasts.load(Ordering::SeqCst), 1);
}
