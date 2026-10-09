//! Read-only Electrum diagnostic. No wallet or seed is created.
#[tokio::main]
async fn main() -> anyhow::Result<()> {
	let mut args = std::env::args().skip(1);
	let endpoint = args.next().unwrap_or_else(|| "ssl://pool.paperclip-xbt.xyz:50002".into());
	let pin = args.next();
	let client = bark::electrum::Electrum::connect(endpoint, None, pin, bitcoin::Network::Bitcoin).await?;
	let tip = client.tip().await?;
	let reference = client.block_ref(tip).await?;
	println!("XBT Electrum connected: height {tip}, block {}", reference.hash);
	println!("Ark capability metadata: {}", client.ark_capabilities().await?);
	match client.require_funded_policy().await { Ok(()) => println!("Ark admission policy: compatible"), Err(e) => println!("Ark admission policy: {e}") }
	Ok(())
}
