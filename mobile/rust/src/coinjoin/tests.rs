use super::*;
use bitcoin::hashes::Hash;
#[test]
fn named_account_and_round_state_survive_full_database_backup() {
	let rt = tokio::runtime::Runtime::new().unwrap();
	rt.block_on(async {
		let path = std::env::temp_dir().join(format!(
			"coinjoin-account-{}.sqlite",
			hex(&crypto::random(8))
		));
		let db = Arc::new(SqliteClient::open(&path).unwrap());
		let mut ordinary = OnchainWallet::load_or_create(Network::Regtest, [7; 64], db.clone())
			.await
			.unwrap();
		let hot = ordinary.address().await.unwrap();
		let mut cj = OnchainWallet::load_coinjoin(
			Network::Regtest,
			[7; 64],
			Arc::new((*db).clone().with_bdk_namespace("kilojoin-bip84")),
		)
		.await
		.unwrap();
		let a = cj.address().await.unwrap();
		let b = cj.address().await.unwrap();
		assert_ne!(a, hot);
		assert!(a.script_pubkey().is_p2wpkh());
		let state = load(&path).unwrap();
		save(&path, &state).unwrap();
		let backup = path.with_extension("backup");
		rusqlite::Connection::open(&path)
			.unwrap()
			.execute("VACUUM INTO ?1", [backup.to_str().unwrap()])
			.unwrap();
		let restored = OnchainWallet::load_coinjoin(
			Network::Regtest,
			[7; 64],
			Arc::new(
				SqliteClient::open(&backup)
					.unwrap()
					.with_bdk_namespace("kilojoin-bip84"),
			),
		)
		.await
		.unwrap();
		assert_eq!(restored.peek_address(KeychainKind::External, 1).address, b);
		assert_eq!(restored.derivation_index(KeychainKind::External), Some(1));
		assert!(load(&backup).is_ok());
		std::fs::remove_file(path).unwrap();
		std::fs::remove_file(backup).unwrap();
	});
}

#[test]
fn single_coin_transfer_never_adds_other_coins_and_preserves_unified_signatures() {
	let master = Xpriv::new_master(Network::Regtest, &[9; 64]).unwrap();
	let mut wallet = bdk_wallet::Wallet::create(
		bdk_wallet::template::Bip84(master, KeychainKind::External),
		bdk_wallet::template::Bip84(master, KeychainKind::Internal),
	)
	.network(Network::Regtest)
	.create_wallet_no_persist()
	.unwrap();
	let address = wallet.reveal_next_address(KeychainKind::External).address;
	let tx = Transaction {
		version: bitcoin::transaction::Version::TWO,
		lock_time: bitcoin::absolute::LockTime::ZERO,
		input: vec![bitcoin::TxIn {
			previous_output: OutPoint {
				txid: bitcoin::Txid::from_str(&"11".repeat(32)).unwrap(),
				vout: 0,
			},
			..Default::default()
		}],
		output: vec![
			TxOut {
				value: Amount::from_sat(50000),
				script_pubkey: address.script_pubkey(),
			},
			TxOut {
				value: Amount::from_sat(90000),
				script_pubkey: address.script_pubkey(),
			},
		],
	};
	wallet.apply_unconfirmed_txs([(tx.clone(), 1)]);
	let out = OutPoint {
		txid: tx.compute_txid(),
		vout: 0,
	};
	let destination = wallet.reveal_next_address(KeychainKind::External).address;
	let rate = bitcoin::FeeRate::from_sat_per_vb(2).unwrap();
	let mut drain =
		single_coin_tx(&mut wallet, out, destination.script_pubkey(), None, rate).unwrap();
	assert_eq!(drain.unsigned_tx.input.len(), 1);
	assert_eq!(drain.unsigned_tx.output.len(), 1);
	assert_eq!(
		drain.unsigned_tx.output[0].value.to_sat() + drain.fee().unwrap().to_sat(),
		50000
	);
	let key = derive(&[9; 64], Network::Regtest, "m/84'/1'/0'/0/0").unwrap();
	let coin = Coin {
		txid: out.txid.to_string(),
		vout: out.vout,
		value: 50000,
		pubkey: bitcoin::secp256k1::PublicKey::from_secret_key(&Secp256k1::new(), &key).to_string(),
	};
	let unsigned = drain.clone();
	sign_single_coin(&mut drain, &coin, &key).unwrap();
	let mut expected = unsigned.clone();
	crate::hardware::prepare(&mut expected).unwrap();
	let verified = crate::hardware::signed_transaction(&expected, &drain.serialize()).unwrap();
	assert_eq!(verified.compute_txid(), unsigned.unsigned_tx.compute_txid());
	let mut bad = unsigned;
	bad.inputs[0].sighash_type = Some(bitcoin::psbt::PsbtSighashType::from_u32(1));
	assert!(sign_single_coin(&mut bad, &coin, &key).is_err());
	let signed = drain.extract_tx().unwrap();
	assert_eq!(
		signed.input[0].witness.iter().next().unwrap().last(),
		Some(&0x21)
	);
	assert!(
		single_coin_tx(
			&mut wallet,
			out,
			destination.script_pubkey(),
			Some(70000),
			rate
		)
		.is_err(),
		"must not select the second coin to cover the amount"
	);
	let exact = single_coin_tx(
		&mut wallet,
		out,
		destination.script_pubkey(),
		Some(10209),
		rate,
	)
	.unwrap();
	assert_eq!(exact.unsigned_tx.input.len(), 1);
	assert_eq!(exact.unsigned_tx.output.len(), 2);
	assert!(
		exact
			.unsigned_tx
			.output
			.iter()
			.any(|o| o.value.to_sat() == 10209)
	);
}
#[test]
fn public_library_digest_matches_wallet_fork_digest() {
	let v: Value = serde_json::from_str(include_str!(
		"../../../Tests/PaperclipMobileTests/Fixtures/kilojoin.json"
	))
	.unwrap();
	let tx: Transaction = bitcoin::consensus::deserialize(
		&bytes(v["transaction"]["raw_tx"].as_str().unwrap()).unwrap(),
	)
	.unwrap();
	let previous = tx
		.input
		.iter()
		.enumerate()
		.map(|(i, input)| {
			let pk = bitcoin::PublicKey::from_slice(input.witness.iter().nth(1).unwrap()).unwrap();
			TxOut {
				value: Amount::from_sat(if i == 0 { 50000 } else { 60000 }),
				script_pubkey: bitcoin::ScriptBuf::new_p2wpkh(&pk.wpubkey_hash().unwrap()),
			}
		})
		.collect::<Vec<_>>();
	for i in 0..2 {
		let script = previous[i].script_pubkey.p2wpkh_script_code().unwrap();
		let digest = bitcoin_ext::unified::digest(
			&tx,
			i,
			&previous,
			0x21,
			bitcoin_ext::unified::Execution {
				script_type: 1,
				script_code: Some(&script),
				annex: None,
				leaf: None,
			},
		)
		.unwrap();
		assert_eq!(
			digest.to_string(),
			v["transaction"][format!("unified_sighash_input{i}")]
		);
	}
}

#[test]
fn segregated_coinjoin_derivation_and_legacy_upgrade_preserve_coins() {
	let rt = tokio::runtime::Runtime::new().unwrap();
	rt.block_on(async {
		let dir =
			std::env::temp_dir().join(format!("coinjoin-upgrade-{}", hex(&crypto::random(8))));
		std::fs::create_dir(&dir).unwrap();
		let path = dir.join("db.sqlite");
		let seed = [19; 64];
		let db = SqliteClient::open(&path).unwrap();
		let mut legacy = OnchainWallet::load_coinjoin(
			Network::Bitcoin,
			seed,
			Arc::new(db.clone().with_bdk_namespace("kilojoin-bip84")),
		)
		.await
		.unwrap();
		let old_address = legacy.address().await.unwrap();
		bdk_wallet::test_utils::insert_checkpoint(
			&mut legacy.inner,
			bdk_wallet::chain::BlockId {
				height: 1000,
				hash: "00".repeat(32).parse().unwrap(),
			},
		);
		bdk_wallet::test_utils::receive_output_in_latest_block(
			&mut legacy.inner,
			Amount::from_sat(20000),
		);
		legacy.persist().await.unwrap();
		let mut pending = load(&path).unwrap();
		pending.pending.push(Transaction {
			version: bitcoin::transaction::Version::TWO,
			lock_time: bitcoin::absolute::LockTime::ZERO,
			input: vec![],
			output: vec![],
		});
		save(&path, &pending).unwrap();
		assert!(
			dispatch(
				&dir,
				seed,
				Network::Bitcoin,
				None,
				None,
				&json!({"op":"coinjoin_migrate"})
			)
			.await
			.is_err()
		);
		assert!(legacy_account(&path).unwrap());
		save(&path, &State::default()).unwrap();
		assert!(legacy_account(&path).unwrap());
		dispatch(
			&dir,
			seed,
			Network::Bitcoin,
			None,
			None,
			&json!({"op":"coinjoin_migrate"}),
		)
		.await
		.unwrap();
		assert!(!legacy_account(&path).unwrap());
		let main = OnchainWallet::load_segwit_account(
			Network::Bitcoin,
			seed,
			Arc::new(db.clone().with_bdk_namespace("main-bip84")),
			0,
		)
		.await
		.unwrap();
		assert_eq!(main.balance().total().to_sat(), 20000);
		assert_eq!(
			main.peek_address(KeychainKind::External, 0).address,
			old_address
		);
		let mut cj = OnchainWallet::load_segwit_account(
			Network::Bitcoin,
			seed,
			Arc::new(db.with_bdk_namespace("kilojoin-bip84-v2")),
			1,
		)
		.await
		.unwrap();
		assert_ne!(cj.address().await.unwrap(), old_address);
		assert_eq!(cj.balance().total().to_sat(), 0);
		bdk_wallet::test_utils::insert_checkpoint(
			&mut cj.inner,
			bdk_wallet::chain::BlockId {
				height: 1000,
				hash: "00".repeat(32).parse().unwrap(),
			},
		);
		bdk_wallet::test_utils::receive_output_in_latest_block(
			&mut cj.inner,
			Amount::from_sat(30000),
		);
		let out = cj.list_unspent()[0].outpoint;
		let (_, path, _) = coin(&cj, out, &seed, Network::Bitcoin, 1).unwrap();
		assert!(path.starts_with("m/84'/0'/1'/"));
		assert!(coin(&cj, out, &seed, Network::Bitcoin, 0).is_err());
		std::fs::remove_dir_all(dir).unwrap();
	});
}

#[test]
fn every_coin_in_multi_input_round_stays_reserved_after_signature() {
	let key = crypto::key(&hex(&[1; 32])).unwrap();
	let make_coin = |id: u8| Coin {
		txid: hex(&[id; 32]),
		vout: 0,
		value: 50_000,
		pubkey: bitcoin::secp256k1::PublicKey::from_secret_key(&Secp256k1::new(), &key).to_string(),
	};
	let first = make_coin(2);
	let second = make_coin(3);
	let (blind_key, blind_secret) = paperclip_kilojoin::blind::generate().unwrap();
	let pool = crypto::secret();
	let creator = crypto::secret();
	let terms = Terms {
		v: 3,
		script: "p2wpkh".into(),
		max_inputs: 10,
		outputs: 1,
		creator: crypto::public(&creator).unwrap(),
		blind_key,
		network: "blake2b".into(),
		id: hex(&[4; 8]),
		public_key: crypto::public(&pool).unwrap(),
		denomination: 10_000,
		fee_rate: 2.0,
		min_peers: 2,
		max_peers: 5,
		private: false,
		timeout: 2_000_000_000,
		state: "open".into(),
		peers: 1,
	};
	let mut r = Round::new(
		round::RoundConfig {
			terms,
			relay: "wss://test.invalid".into(),
			tor: true,
			pool_secret: Some(pool),
			creator_secret: Some(creator),
			blind_secret: Some(blind_secret),
			coin: first.clone(),
			coin_path: "first".into(),
			extra_coins: vec![(second.clone(), "second".into(), key)],
			mix_script: format!("0014{}", hex(&[8; 20])),
			extra_mixes: vec![],
			change_script: format!("0014{}", hex(&[9; 20])),
			password: None,
		},
		&key,
		1_791_400_000,
	)
	.unwrap();
	r.signed = true;
	r.phase = "uncertain".into();
	let mut s = State::default();
	s.rounds.push(r);
	assert!(!available(&s, first.outpoint().unwrap()));
	assert!(!available(&s, second.outpoint().unwrap()));
	s.rounds[0].phase = "aborted".into();
	assert!(!available(&s, second.outpoint().unwrap()));
	s.rounds[0].phase = "confirmed".into();
	assert!(available(&s, second.outpoint().unwrap()));
}

#[test]
fn kilojoin_taproot_digest_matches_native_unified_engine() {
	let key = crypto::key(&hex(&[1; 32])).unwrap();
	let terms = Terms {
		v: 2,
		script: "p2tr".into(),
		max_inputs: 10,
		outputs: 1,
		creator: String::new(),
		blind_key: String::new(),
		network: "blake2b".into(),
		id: hex(&[4; 8]),
		public_key: crypto::public(&hex(&[5; 32])).unwrap(),
		denomination: 10_000,
		fee_rate: 2.0,
		min_peers: 2,
		max_peers: 5,
		private: false,
		timeout: 2_000_000_000,
		state: "open".into(),
		peers: 1,
	};
	let mut seats = Vec::new();
	let mut outputs = Vec::new();
	for n in [2, 3] {
		let c = Coin {
			txid: hex(&[n; 32]),
			vout: 0,
			value: 50_000,
			pubkey: bitcoin::secp256k1::PublicKey::from_secret_key(&Secp256k1::new(), &key)
				.to_string(),
		};
		let output_key = crypto::key(&hex(&[n + 2; 32])).unwrap();
		let change_key = crypto::key(&hex(&[n + 4; 32])).unwrap();
		let spk = |k: &SecretKey| {
			bitcoin::ScriptBuf::new_p2tr(
				&Secp256k1::new(),
				bitcoin::secp256k1::PublicKey::from_secret_key(&Secp256k1::new(), k)
					.x_only_public_key()
					.0,
				None,
			)
			.to_hex_string()
		};
		outputs.push(spk(&output_key));
		seats.push(protocol::Seat {
			token_hash: hex(&[n; 32]),
			coin: c,
			coins: vec![],
			join_pub: String::new(),
			proofs: vec![],
			change_script: spk(&change_key),
			change_value: terms.change(50_000, 1).unwrap(),
		});
	}
	let p = protocol::Plan::new(&terms, &seats, &outputs, &seats[0], &outputs[0]).unwrap();
	let expected = bitcoin_ext::unified::digest(
		&p.tx,
		0,
		&p.previous,
		0x21,
		bitcoin_ext::unified::Execution {
			script_type: 2,
			script_code: None,
			annex: None,
			leaf: None,
		},
	)
	.unwrap();
	assert_eq!(p.digest(0).unwrap(), expected.to_byte_array());
	let sig = p.sign(&seats[0].coin, &key).unwrap();
	assert_eq!(bytes(&sig).unwrap().len(), 65);
	p.verify(&seats[0].coin.name(), &sig).unwrap();
}
