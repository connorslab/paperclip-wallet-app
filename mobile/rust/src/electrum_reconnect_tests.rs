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
					"server.version" => {
						assert_eq!(request["params"][1], json!(["1.8", "1.8"]));
						json!(["test", "1.8"])
					},
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

// Opt-in read-only smoke check against a real XBT server. No wallet or keys used.
#[test]
#[ignore = "requires PAPERCLIP_TEST_ELECTRUM and network access"]
fn electrum_live_headers_and_history() {
	let endpoint = std::env::var("PAPERCLIP_TEST_ELECTRUM").unwrap();
	tokio::runtime::Runtime::new().unwrap().block_on(async {
		let client = bark::electrum::Electrum::connect(endpoint, None, None, bitcoin::Network::Bitcoin).await.unwrap();
		let height = client.tip().await.unwrap();
		assert!(height > 961640);
		client.block_ref(height).await.unwrap();
		client.run(|c| {
			// Public OP_RETURN scripts cannot receive spendable coins.
			let scripts: Vec<_> = (0..20).map(|n| bitcoin::ScriptBuf::from_bytes(vec![0x6a, 1, n])).collect();
			let history = c.inner.batch_script_get_history(scripts.iter().map(|s| s.as_script()))?;
			assert_eq!(history.len(), 20);
			Ok(())
		}).await.unwrap();
	});
}

#[test]
fn interrupt_stalled_electrum_read_then_reconnect() {
	let listener = TcpListener::bind("127.0.0.1:0").unwrap();
	let endpoint = format!("tcp://{}", listener.local_addr().unwrap());
	let (started, waiting) = std::sync::mpsc::channel();
	let server = std::thread::spawn(move || {
		for connection in 0..2 {
			let (mut stream, _) = listener.accept().unwrap();
			stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
			let mut reader = BufReader::new(stream.try_clone().unwrap());
			loop {
				let mut line = String::new();
				if reader.read_line(&mut line).unwrap() == 0 { break; }
				let request: Value = serde_json::from_str(&line).unwrap();
				let method = request["method"].as_str().unwrap();
				if method == "blockchain.scripthash.get_history" {
					started.send(()).unwrap();
					// Deliberately withhold a response. Cancellation must close the socket.
					assert_eq!(reader.read_line(&mut String::new()).unwrap(), 0);
					break;
				}
				let result = match method {
					"server.version" => json!(["test", "1.8"]),
					"blockchain.block.header" => json!(bitcoin::consensus::encode::serialize_hex(&bitcoin::constants::genesis_block(bitcoin::Network::Bitcoin).header)),
					"blockchain.headers.subscribe" => json!({"height":975000,"hex":"00".repeat(164)}),
					"server.ping" => Value::Null,
					_ => panic!("unexpected method {method}"),
				};
				writeln!(stream, "{}", json!({"id":request["id"],"result":result})).unwrap();
				if connection == 1 && method == "server.ping" { break; }
			}
		}
	});
	tokio::runtime::Runtime::new().unwrap().block_on(async {
		let client = bark::electrum::Electrum::connect(endpoint, None, None, bitcoin::Network::Bitcoin).await.unwrap();
		let other = client.clone();
		let blocked = tokio::spawn(async move {
			other.run(|c| Ok(c.inner.raw_call("blockchain.scripthash.get_history", Vec::<bdk_electrum::electrum_client::Param>::new())?)).await
		});
		tokio::task::spawn_blocking(move || waiting.recv_timeout(Duration::from_secs(5)).unwrap()).await.unwrap();
		client.interrupt_read();
		assert!(tokio::time::timeout(Duration::from_secs(1), blocked).await.unwrap().unwrap().is_err());
		client.run(|c| Ok(c.inner.ping()?)).await.unwrap();
	});
	server.join().unwrap();
}

#[test]
fn scan_interruption_leaves_original_connection_usable() {
	let listener = TcpListener::bind("127.0.0.1:0").unwrap();
	let endpoint = format!("tcp://{}", listener.local_addr().unwrap());
	let (started, waiting) = std::sync::mpsc::channel();
	let server = std::thread::spawn(move || {
		let mut threads = Vec::new();
		for _ in 0..2 {
			let (mut stream, _) = listener.accept().unwrap();
			let started = started.clone();
			threads.push(std::thread::spawn(move || {
				stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
				let mut reader = BufReader::new(stream.try_clone().unwrap());
				loop {
					let mut line = String::new();
					if reader.read_line(&mut line).unwrap() == 0 { break; }
					let request: Value = serde_json::from_str(&line).unwrap();
					let result = match request["method"].as_str().unwrap() {
						"server.version" => json!(["test", "1.8"]),
						"blockchain.block.header" => json!(bitcoin::consensus::encode::serialize_hex(&bitcoin::constants::genesis_block(bitcoin::Network::Bitcoin).header)),
						"blockchain.headers.subscribe" => json!({"height":975000,"hex":"00".repeat(164)}),
						"server.ping" => Value::Null,
						"blockchain.scripthash.get_history" => {
							started.send(()).unwrap();
							assert_eq!(reader.read_line(&mut String::new()).unwrap(), 0);
							break;
						},
						other => panic!("unexpected method {other}"),
					};
					writeln!(stream, "{}", json!({"id":request["id"],"result":result})).unwrap();
				}
			}));
		}
		for thread in threads { thread.join().unwrap(); }
	});
	tokio::runtime::Runtime::new().unwrap().block_on(async {
		let original = bark::electrum::Electrum::connect(endpoint, None, None, bitcoin::Network::Bitcoin).await.unwrap();
		let scan = original.isolated_read_connection().await.unwrap();
		let other = scan.clone();
		let blocked = tokio::spawn(async move {
			other.run(|c| Ok(c.inner.raw_call("blockchain.scripthash.get_history", Vec::<bdk_electrum::electrum_client::Param>::new())?)).await
		});
		tokio::task::spawn_blocking(move || waiting.recv_timeout(Duration::from_secs(5)).unwrap()).await.unwrap();
		scan.interrupt_read();
		assert!(tokio::time::timeout(Duration::from_secs(1), blocked).await.unwrap().unwrap().is_err());
		original.run(|c| Ok(c.inner.ping()?)).await.unwrap();
	});
	server.join().unwrap();
}
