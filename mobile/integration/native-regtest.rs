//! Run through the paired ASP's isolated `just int` harness, never production.
use std::process::Stdio;
use std::time::Duration;
use ark_testing::{btc, sat, TestContext};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use server::vtxopool::VtxoTarget;

struct Mobile {
	_child: Child,
	input: ChildStdin,
	output: Lines<BufReader<ChildStdout>>,
}
impl Mobile {
	fn start() -> Self {
		let mut child = Command::new(std::env::var("PAPERCLIP_MOBILE_LAB_BIN").unwrap())
			.stdin(Stdio::piped()).stdout(Stdio::piped()).kill_on_drop(true).spawn().unwrap();
		Self { input: child.stdin.take().unwrap(), output: BufReader::new(child.stdout.take().unwrap()).lines(), _child: child }
	}
	async fn raw(&mut self, request: Value) -> Value {
		self.input.write_all(format!("{request}\n").as_bytes()).await.unwrap();
		let line = tokio::time::timeout(Duration::from_secs(60), self.output.next_line()).await.unwrap().unwrap().unwrap();
		serde_json::from_str(&line).unwrap()
	}
	async fn call(&mut self, request: Value) -> Value {
		let response = self.raw(request).await;
		assert!(response.get("error").is_none(), "{response}");
		response["ok"].clone()
	}
	async fn pay(&mut self, destination: String, amount: u64, onchain: bool) -> Value {
		let quote = self.call(json!({"op": if onchain {"quote_onchain"} else {"quote"}, "destination": destination, "amount_sat": amount})).await;
		let request = json!({"op": if onchain {"send_onchain"} else {"send"}, "destination": destination, "amount_sat": amount, "total_sat": quote["total_sat"]});
		let result = self.call(request.clone()).await;
		assert!(self.raw(request).await.get("error").is_some(), "a consumed quote must not send twice");
		result
	}
	async fn wait_paid(&mut self, payment_hash: Value) {
		for _ in 0..30 {
			let result = self.call(json!({"op": "check_payment", "payment_hash": payment_hash})).await;
			if result["state"] == "paid" { return; }
			tokio::time::sleep(Duration::from_secs(1)).await;
		}
		panic!("Lightning payment did not settle");
	}
}

#[tokio::test]
async fn xbt_mobile_native_transactions() {
	let ctx = TestContext::new("xbt/mobile-native").await;
	let ln = ctx.new_lightning_setup("mobile-ln").await;
	let server = ctx.captaind("asp").lightningd(&ln.internal).funded(btc(2)).cfg(|c| {
		c.experimental_funded_lightning = true;
		c.vtxopool.vtxo_targets = vec![VtxoTarget { amount: sat(200_000), count: 4 }];
	}).create().await;
	server.wait_for_vtxopool(&ctx).await;
	let donor = ctx.bark("donor", &server).funded(sat(1_000_000)).create().await;
	donor.board_and_confirm_and_register(&ctx, sat(800_000)).await;
	let receiver = ctx.bark("receiver", &server).create().await;
	let mut mobile = Mobile::start();
	let dir = ctx.datadir.join("mobile-wallet");
	mobile.call(json!({"op": "create", "network": "xbt-regtest", "directory": dir})).await;
	let mut config = mobile.call(json!({"op": "config_template"})).await;
	config["server_address"] = json!(server.ark_url());
	config["esplora_address"] = Value::Null;
	config["bitcoind_address"] = json!(ctx.bitcoind().rpc_url());
	config["bitcoind_cookiefile"] = json!(ctx.bitcoind().rpc_cookie());
	config["fallback_fee_rate"] = json!(250);
	mobile.call(json!({"op": "connect", "config": config})).await;
	let address = mobile.call(json!({"op": "address_onchain"})).await;
	ctx.bitcoind().fund_addr(address["address"].as_str().unwrap(), sat(1_000_000)).await;
	ctx.generate_blocks(1).await;
	let balances = mobile.call(json!({"op": "sync"})).await;
	assert_eq!(balances["onchain_sat"], 1_000_000);
	let sent = mobile.pay(receiver.get_onchain_address().await.to_string(), 50_000, true).await;
	assert_eq!(sent["state"], "submitted");
	ctx.generate_blocks(1).await;
	assert!(receiver.onchain_balance().await >= sat(50_000));
	let ark_address = mobile.call(json!({"op": "address_ark"})).await;
	donor.send_oor(ark_address["address"].as_str().unwrap(), sat(400_000)).await;
	let balances = mobile.call(json!({"op": "sync"})).await;
	assert_eq!(balances["ark_sat"], 400_000);
	mobile.pay(receiver.address().await, 50_000, false).await;
	assert_eq!(receiver.spendable_balance().await, sat(50_000));
	ln.sync().await;
	let invoice = ln.external.invoice(Some(sat(20_000)), "mobile-send", "Mobile bridge").await;
	let payment = mobile.pay(invoice.to_string(), 20_000, false).await;
	mobile.wait_paid(payment["payment_hash"].clone()).await;
	ln.external.wait_invoice_paid("mobile-send").await;
	let offer = ln.external.offer(Some(sat(20_000)), Some("Mobile BOLT12")).await;
	let payment = mobile.pay(offer.to_string(), 20_000, false).await;
	mobile.wait_paid(payment["payment_hash"].clone()).await;
	mobile.call(json!({"op": "close"})).await;
	mobile.call(json!({"op": "open", "network": "xbt-regtest", "directory": dir})).await;
	mobile.call(json!({"op": "connect", "config": config})).await;
	assert_eq!(mobile.call(json!({"op": "check_payment", "payment_hash": payment["payment_hash"]})).await["state"], "paid");
}
