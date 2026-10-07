use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;
use std::time::{Duration, Instant};

use bitcoin_ext::rpc::{Auth, BitcoinRpcClient, RpcApi};
use serde_json::{json, Value};

fn accept(listener: &TcpListener) -> TcpStream {
	listener.set_nonblocking(true).unwrap();
	let deadline = Instant::now() + Duration::from_secs(10);
	loop {
		match listener.accept() {
			Ok((stream, _)) => return stream,
			Err(error) if error.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
			Err(error) => panic!("SOCKS client did not connect: {error}"),
		}
	}
}

fn proxy(status: u16, location: Option<String>, tls: bool) -> (String, thread::JoinHandle<()>) {
	let listener = TcpListener::bind("127.0.0.1:0").unwrap();
	let address = format!("socks5h://{}", listener.local_addr().unwrap());
	let task = thread::spawn(move || {
		let mut stream = accept(&listener);
		stream.set_nonblocking(false).unwrap();
		stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
		let mut greeting = [0; 2];
		stream.read_exact(&mut greeting).unwrap();
		assert_eq!(greeting[0], 5);
		let mut methods = vec![0; greeting[1] as usize];
		stream.read_exact(&mut methods).unwrap();
		assert!(methods.contains(&0));
		stream.write_all(&[5, 0]).unwrap();
		let mut request = [0; 5];
		stream.read_exact(&mut request).unwrap();
		assert_eq!(&request[..4], &[5, 1, 0, 3]); // Hostname sent to proxy, no local DNS.
		let mut hostname = vec![0; request[4] as usize];
		stream.read_exact(&mut hostname).unwrap();
		assert_eq!(hostname, b"paperclip-test.onion");
		let mut port = [0; 2];
		stream.read_exact(&mut port).unwrap();
		assert_eq!(u16::from_be_bytes(port), 8332);
		stream.write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 0]).unwrap();
		if tls {
			let mut record = [0; 3];
			stream.read_exact(&mut record).unwrap();
			assert_eq!(&record[..2], &[0x16, 0x03]);
			return;
		}
		let mut headers = Vec::new();
		while !headers.ends_with(b"\r\n\r\n") {
			let mut byte = [0];
			stream.read_exact(&mut byte).unwrap();
			headers.push(byte[0]);
			assert!(headers.len() < 16_384);
		}
		let headers = String::from_utf8(headers).unwrap().to_lowercase();
		assert!(headers.contains("authorization: basic dgvzddpzzwnyzxq="));
		let size: usize = headers.lines().find_map(|line| line.strip_prefix("content-length:")).unwrap().trim().parse().unwrap();
		let mut body = vec![0; size];
		stream.read_exact(&mut body).unwrap();
		let request: Value = serde_json::from_slice(&body).unwrap();
		assert_eq!(request["method"], "getblockcount");
		let body = if status == 500 {
			json!({"id": request["id"], "result": null, "error": {"code": -26, "message": "policy rejection"}})
		} else { json!({"id": request["id"], "result": 123, "error": null}) }.to_string();
		let location = location.map(|url| format!("Location: {url}\r\n")).unwrap_or_default();
		write!(stream, "HTTP/1.1 {status} Test\r\n{location}Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
	});
	(address, task)
}

fn call(async_client: bool, url: &str, proxy: &str) -> Result<Value, String> {
	if async_client {
		let client = bitcoind_async_client::Client::new(url.into(), bitcoind_async_client::Auth::UserPass("test".into(), "secret".into()), Some(0), None, Some(5))
			.unwrap().with_socks5_proxy(proxy).unwrap();
		tokio::runtime::Runtime::new().unwrap().block_on(client.call_raw("getblockcount", &[])).map_err(|e| e.to_string())
	} else {
		BitcoinRpcClient::new_with_proxy(url, Auth::UserPass("test".into(), "secret".into()), Some(proxy))
			.unwrap().call("getblockcount", &[]).map_err(|e| e.to_string())
	}
}

#[test]
fn rpc_tor_both_clients_use_remote_dns_and_preserve_node_errors() {
	for async_client in [false, true] {
		for status in [200, 500] {
			let (proxy, task) = proxy(status, None, false);
			let result = call(async_client, "http://paperclip-test.onion:8332", &proxy);
			task.join().unwrap();
			if status == 200 { assert_eq!(result.unwrap(), json!(123)); }
			else { assert!(result.unwrap_err().contains("policy rejection")); }
		}
	}
}

#[test]
fn rpc_tor_both_clients_preserve_tls_inside_proxy() {
	for async_client in [false, true] {
		let (proxy, task) = proxy(200, None, true);
		assert!(call(async_client, "https://paperclip-test.onion:8332", &proxy).is_err());
		task.join().unwrap();
	}
}

#[test]
fn rpc_tor_never_falls_back_or_follows_redirects() {
	for async_client in [false, true] {
		let direct = TcpListener::bind("127.0.0.1:0").unwrap();
		direct.set_nonblocking(true).unwrap();
		let url = format!("http://{}", direct.local_addr().unwrap());
		let closed = TcpListener::bind("127.0.0.1:0").unwrap();
		let unavailable_proxy = format!("socks5h://{}", closed.local_addr().unwrap());
		drop(closed);
		assert!(call(async_client, &url, &unavailable_proxy).is_err());
		assert_eq!(direct.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
		let (proxy, task) = proxy(302, Some(url), false);
		assert!(call(async_client, "http://paperclip-test.onion:8332", &proxy).is_err());
		task.join().unwrap();
		assert_eq!(direct.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
	}
}

#[test]
fn rpc_tor_rejects_proxy_schemes_that_allow_local_dns() {
	let url = "http://paperclip-test.onion:8332";
	let proxy = "socks5://127.0.0.1:9050";
	assert!(BitcoinRpcClient::new_with_proxy(url, Auth::UserPass("test".into(), "secret".into()), Some(proxy)).is_err());
	assert!(bitcoind_async_client::Client::new(url.into(), bitcoind_async_client::Auth::UserPass("test".into(), "secret".into()), None, None, None)
		.unwrap().with_socks5_proxy(proxy).is_err());
}
