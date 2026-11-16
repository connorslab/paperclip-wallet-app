//! New hot-wallet entropy. The dice derivation matches both mobile clients.
use std::str::FromStr;

use anyhow::{Context, ensure};
use bip39::Mnemonic;
use bitcoin::hashes::{Hash, sha256};
use bitcoin::secp256k1::rand::{RngCore, rngs::OsRng};
use bark_json::web::SeedGeneration;

pub fn resolve(mnemonic: Option<String>, generation: Option<SeedGeneration>) -> anyhow::Result<Option<Mnemonic>> {
	ensure!(mnemonic.is_none() || generation.is_none(), "Choose restore or generation, not both");
	if let Some(phrase) = mnemonic {
		return Ok(Some(Mnemonic::from_str(&phrase).context("Invalid seed phrase")?));
	}
	let Some(generation) = generation else { return Ok(None); };
	let bytes = entropy(generation)?;
	Ok(Some(Mnemonic::from_entropy(&bytes).context("Invalid entropy size")?))
}

fn entropy(generation: SeedGeneration) -> anyhow::Result<Vec<u8>> {
	let words = match &generation { SeedGeneration::System { words } | SeedGeneration::Dice { words, .. } => *words };
	ensure!(words == 12 || words == 24, "Choose a 12- or 24-word phrase");
	let count = if words == 12 { 16 } else { 32 };
	match generation {
		SeedGeneration::System { .. } => {
			let mut bytes = vec![0; count];
			OsRng.try_fill_bytes(&mut bytes).context("Secure system randomness is unavailable")?;
			Ok(bytes)
		},
		SeedGeneration::Dice { sides, rolls, fair_dice_acknowledged, .. } => {
			ensure!(fair_dice_acknowledged, "Confirm independent rolls with fair physical dice");
			let minimum = match sides { 6 => 50, 12 => 36, 20 => 30, _ => anyhow::bail!("Choose D6, D12 or D20") }
				* if words == 12 { 1 } else { 2 };
			ensure!((minimum..=1000).contains(&rolls.len()), "Complete the required dice rolls, up to 1000");
			ensure!(rolls.iter().all(|roll| (1..=sides).contains(roll)), "Invalid physical dice result");
			let input = format!("Paperclip/dice/v1/sides={}\n{}", sides,
				rolls.iter().map(u8::to_string).collect::<Vec<_>>().join(","));
			Ok(sha256::Hash::hash(input.as_bytes()).to_byte_array()[..count].to_vec())
		},
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn dice(words: u8, sides: u8, rolls: Vec<u8>) -> SeedGeneration {
		SeedGeneration::Dice { words, sides, rolls, fair_dice_acknowledged: true }
	}

	#[test]
	fn dice_matches_mobile_vectors_and_uses_every_roll() {
		// Predictable synthetic fixtures only. Never use these to create a wallet.
		for (sides, minimum, hex) in [(6, 50, "ec28f632c842726f6ed490c9115f9d32"),
			(12, 36, "28f23d996c90d93745bc88f05c6103c4"), (20, 30, "91a93aac185e128e5dd9f7aa027092bf")] {
			let rolls: Vec<u8> = (0..minimum).map(|i| (i % sides as usize + 1) as u8).collect();
			let expected: Vec<u8> = (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i+2], 16).unwrap()).collect();
			assert_eq!(entropy(dice(12, sides, rolls.clone())).unwrap(), expected);
			for words in [12, 24] {
				let mut rolls = if words == 12 { rolls.clone() } else { rolls.repeat(2) };
				let original = entropy(dice(words, sides, rolls.clone())).unwrap();
				assert_eq!(original.len(), if words == 12 { 16 } else { 32 });
				rolls.pop();
				assert!(entropy(dice(words, sides, rolls.clone())).is_err());
				rolls.resize(1000, 1);
				let full = entropy(dice(words, sides, rolls.clone())).unwrap();
				rolls[999] = sides;
				assert_ne!(full, entropy(dice(words, sides, rolls.clone())).unwrap());
				rolls.push(1);
				assert!(entropy(dice(words, sides, rolls)).is_err());
			}
		}
	}

	#[test]
	fn invalid_entropy_never_falls_back_to_random_generation() {
		for input in [dice(15, 6, vec![1; 100]), dice(12, 8, vec![1; 100]),
			dice(12, 6, vec![0; 100]), dice(12, 6, vec![7; 100]),
			SeedGeneration::Dice { words: 12, sides: 6, rolls: vec![1; 100], fair_dice_acknowledged: false }] {
			assert!(resolve(None, Some(input)).is_err());
		}
		assert!(resolve(Some(String::new()), Some(SeedGeneration::System { words: 12 })).is_err());
		for words in [12, 24] {
			assert_eq!(resolve(None, Some(SeedGeneration::System { words })).unwrap().unwrap().word_count(), words as usize);
		}
		assert!(resolve(None, None).unwrap().is_none());
		for value in [r#"{"method":"unknown","words":12}"#, r#"{"method":"system","words":12,"rolls":[1]}"#,
			r#"{"method":"dice","words":12,"sides":6,"rolls":[1.5],"fair_dice_acknowledged":true}"#] {
			assert!(serde_json::from_str::<SeedGeneration>(value).is_err());
		}
	}
}
