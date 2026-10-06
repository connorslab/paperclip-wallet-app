//! Read-only Electrum diagnostic. No wallet or seed is created.
#[tokio::main]
async fn main() -> anyhow::Result<()> {
	let mut args = std::env::args().skip(1);
	let endpoint = args.next().unwrap_or_else(|| "ssl://pool.paperclippool.xyz:50002".into());
	let pin = args.next();
	let client = bark::electrum::Electrum::connect(endpoint, None, pin, bitcoin::Network::Bitcoin).await?;
	let tip = client.tip().await?;
	let reference = client.block_ref(tip).await?;
	println!("XBT Electrum connected: height {tip}, block {}", reference.hash);
	Ok(())
}
