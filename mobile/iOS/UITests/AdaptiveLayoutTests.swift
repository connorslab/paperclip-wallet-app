import XCTest

/// Synthetic fixtures only: no wallet credentials, synchronization or payments.
final class AdaptiveLayoutTests: XCTestCase {
    func testQRWalletCanChooseArkRecipientWithoutPreparingPayment() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-build61-preview", "-wallet-shell-preview", "-hardware-boarding-entry-preview", "-appearance", "dark"]
        app.launch()
        let entry = app.buttons["hardware-move-to-ark"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        if !entry.isHittable { app.swipeUp() }
        entry.tap()
        let next = app.buttons["Continue to boarding"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertFalse(next.isEnabled)
        XCTAssertFalse(app.buttons["ark-destination-wrong-network"].exists)
        XCTAssertFalse(app.buttons["ark-destination-watch"].exists)
        app.buttons["ark-destination-preview"].tap()
        capture(app, "Choose Ark receiving wallet")
        next.tap()
        XCTAssertTrue(app.navigationBars["Board to Ark · Beta"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["ark-boarding-source"].exists)
        XCTAssertTrue(app.buttons["ark-boarding-source"].label.contains("My QR signer"))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Everyday wallet")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Confirm and board"].exists)
        capture(app, "QR wallet boarding entry")
        app.navigationBars["Board to Ark · Beta"].buttons.firstMatch.tap()
        XCTAssertFalse(app.navigationBars["Board to Ark · Beta"].exists)
        XCTAssertFalse(app.buttons["hardware-move-to-ark"].exists)
        // Returning to the receiving wallet must not reopen boarding automatically.
        XCTAssertTrue(app.buttons["Active wallet: Everyday wallet. Switch wallet"].waitForExistence(timeout: 5))
        // Never request a quote, generate a PSBT or broadcast in this UI fixture.
    }

	func testReusableBridgeReviewDoesNotRegisterOrSend() {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-bridge-reusable-preview", "-appearance", "dark"]
		app.launch()
		let field = app.descendants(matching: .any).matching(identifier: "bridge-reusable-destination").firstMatch
		XCTAssertTrue(field.waitForExistence(timeout: 15))
		field.tap(); field.typeText("lno1pg89qctsv4exxmrfwqs8getnwsxyzqgqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq93pqfumuen7l8wthtz45p3ftn58pvrs9xlumvkuu2xet8egzkcklqtes")
		app.swipeUp()
		let review = app.buttons["Review offer"]
		XCTAssertTrue(review.waitForExistence(timeout: 10))
		XCTAssertTrue(review.isEnabled)
		review.tap()
		XCTAssertTrue(app.buttons["Create reusable offer"].waitForExistence(timeout: 10))
		XCTAssertFalse(app.buttons["Confirm and send"].exists)
		XCTAssertFalse(app.staticTexts["Your saved offers"].exists)
		capture(app,"Reusable Bridge review")
		app.buttons["Edit"].tap()
		XCTAssertTrue(field.waitForExistence(timeout: 10))
		// Never press Create: this test must not register a production offer.
	}

	func testRecoveredConfirmationShowsOriginalWhenReplacementLostRace() {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-recovered-send-preview", "-confirmed-send-preview", "-appearance", "dark"]
		app.launch()
		XCTAssertTrue(app.staticTexts["Payment completed"].waitForExistence(timeout: 15))
		XCTAssertTrue(app.staticTexts[String(repeating: "ab", count: 32)].exists)
		XCTAssertFalse(app.staticTexts[String(repeating: "cd", count: 32)].exists)
		XCTAssertTrue(app.staticTexts["This payment is complete. View Activity for its details."].exists)
		XCTAssertFalse(app.buttons["Confirm and send"].exists)
		XCTAssertFalse(app.buttons["Review payment"].exists)
	}
	func testSavedSendHasStatusActionAndNoReplayControl() {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-recovered-send-preview", "-appearance", "dark"]
		app.launch()
		let check = app.buttons["send-check-recovered-payment"]
		XCTAssertTrue(check.waitForExistence(timeout: 15))
		XCTAssertTrue(check.isHittable)
		XCTAssertFalse(app.buttons["Confirm payment"].exists)
		XCTAssertFalse(app.buttons["Review payment"].exists)
		check.tap()
		XCTAssertTrue(app.staticTexts["Status unavailable. The saved attempt remains unresolved."].waitForExistence(timeout: 5))
		XCTAssertTrue(app.staticTexts["Saved payment needs checking"].exists)
		XCTAssertFalse(app.buttons["Confirm payment"].exists)
		capture(app, "Saved send recovery")
	}
	func testPairingReviewShowsScopeAndCancelReturnsToSetup() throws {
		try checkPairingReview(scope: "jars_manage_v1", permission: "Sending, key export and your main wallet are not included.")
	}
	func testPaymentPairingReviewExplainsSpendingAndCancelReturnsToSetup() throws {
		try checkPairingReview(scope: "jars_pay_v1", permission: "Allows managing and sending funds")
	}
	func testTorPairingReviewShowsBuiltInTorAndCancelDoesNotConnect() throws {
		try checkPairingReview(scope: "jars_manage_v1", permission: "Sending, key export and your main wallet are not included.", endpoint: "http://" + String(repeating: "a", count: 56) + ".onion")
	}
	private func checkPairingReview(scope: String, permission: String, endpoint: String = "https://host.example.invalid") throws {
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-joinblaket-setup-preview", "-appearance", "dark"]
		app.launch()
		let field = app.secureTextFields["Paste pairing code"]
		XCTAssertTrue(field.waitForExistence(timeout: 15))
		let payload: [String: Any] = ["kind":"paperclip-jars-v1","scope":scope,"endpoint":endpoint, "wallet":"fixture.jmdat",
			"token":"pj1_" + String(repeating:"a",count:64),"expires":4_000_000_000,"certificate_sha256":""]
		let code = "paperclip-jars:" + (try JSONSerialization.data(withJSONObject: payload)).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
		field.tap(); field.typeText(code)
		app.buttons["Review connection"].tap()
		XCTAssertTrue(app.staticTexts[endpoint].exists)
		XCTAssertTrue(app.staticTexts[endpoint.contains(".onion") ? "Built-in Tor" : "HTTPS"].exists)
		XCTAssertTrue(app.staticTexts["fixture.jmdat"].exists)
		XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", permission)).firstMatch.exists)
		let verify = app.buttons["Verify and save connection"]
		if !verify.isHittable { app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(verify.isHittable)
		capture(app, "Jars pairing review")
		app.buttons["Cancel"].tap()
		XCTAssertTrue(app.buttons["Scan pairing code"].exists)
		XCTAssertFalse(verify.exists)
	}
	func testSendReviewIsOneStepAndEditingPreservesRecipient() {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-ark-fee-preview", "-appearance", "dark"]
		app.launch()
		let confirm = app.buttons["Confirm payment"]
		XCTAssertTrue(confirm.waitForExistence(timeout: 15))
		for _ in 0..<3 { if confirm.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(confirm.isHittable)
		XCTAssertFalse(app.buttons["Scan QR code"].exists)
		XCTAssertTrue(app.staticTexts["payment-total-debit"].exists || app.otherElements["payment-total-debit"].exists)
		capture(app, "Send review compact")
		app.buttons["Edit recipient or amount"].tap()
		XCTAssertFalse(confirm.exists)
		XCTAssertTrue(app.buttons["Scan QR code"].exists)
		let recipient = app.textFields["payment-recipient"]
		XCTAssertTrue(recipient.exists)
		XCTAssertEqual(recipient.value as? String, "Ark recipient · simulator preview")
	}

	func testNodeReviewSeparatesFormAndPreservesDraftOnEdit() {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-node-review-preview", "-appearance", "dark"]
		app.launch()
		let confirm = app.buttons["Confirm Lightning payment"]
		XCTAssertTrue(confirm.waitForExistence(timeout: 15))
		for _ in 0..<3 { if confirm.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(confirm.isHittable)
		XCTAssertFalse(app.buttons["Scan QR code"].exists)
		XCTAssertTrue(app.staticTexts["10,000 sats"].exists)
		capture(app, "Lightning review compact")
		app.buttons["View full invoice"].tap()
		XCTAssertTrue(app.staticTexts["Synthetic invoice · no payment"].exists)
		app.buttons["Edit invoice or fee"].tap()
		XCTAssertFalse(confirm.exists)
		XCTAssertTrue(app.buttons["Scan QR code"].exists)
		XCTAssertEqual(app.textFields["node-payment-invoice"].value as? String, "Synthetic invoice · no payment")
		XCTAssertEqual(app.textFields["Maximum routing fee in sats"].value as? String, "100")
	}

	func testJamRecoveryPreservesUnknownOnTimeoutAndNeverClaimsConfirmation() {
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-joinblaket-preview", "-jam-recovery-preview", "-appearance", "dark"]
		app.launch()
		let unknown = app.staticTexts["Status unknown"]
		XCTAssertTrue(unknown.waitForExistence(timeout: 10))
		XCTAssertTrue(app.staticTexts["This payment may have reached the network. Do not send it again."].exists)
		app.buttons["Check status"].tap()
		XCTAssertTrue(app.staticTexts["Could not check payment status. Check your connection and try again."].waitForExistence(timeout: 5))
		XCTAssertTrue(unknown.exists)
		let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "ios-jam-recovery"; attachment.lifetime = .keepAlways; add(attachment)
		app.buttons["Check status"].tap()
		XCTAssertTrue(app.staticTexts["Submitted"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.staticTexts["Seen by your node. Confirmation has not been checked."].exists)
		XCTAssertFalse(app.buttons["Check status"].exists)
		app.buttons["Done"].tap()
		XCTAssertTrue(app.buttons["jar-0"].waitForExistence(timeout: 5))
	}

	func testCompactJarSelectionKeepsAccountActionsNearby() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-joinblaket-preview", "-appearance", "dark"]
		app.launch()
		let first = app.buttons["jar-0"]
		XCTAssertTrue(first.waitForExistence(timeout: 15))
		XCTAssertTrue(first.isSelected)
		for id in 0..<5 { XCTAssertTrue(app.buttons["jar-\(id)"].isHittable, "Every jar should be visible without scrolling") }
		let second = app.buttons["jar-1"]
		let last = app.buttons["jar-4"]
		XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 2)
		XCTAssertEqual(last.frame.midX, (first.frame.minX + second.frame.maxX) / 2, accuracy: 2)
		XCTAssertEqual(last.frame.width, first.frame.width, accuracy: 2)
		capture(app, "iOS Jars grid")
		last.tap()
		XCTAssertTrue(last.isSelected)
		XCTAssertTrue(app.buttons["Receive into Elderberry"].exists)
		XCTAssertFalse(app.buttons["Receive into Elderberry"].isEnabled)
	}
	func testJarSendCoinJoinChoiceNeverFallsBackInPreview() {
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-joinblaket-preview", "-appearance", "dark"]
		app.launch()
		XCTAssertTrue(app.navigationBars["Jars"].waitForExistence(timeout: 15))
		let send = app.buttons["Send from Apricot"]
		for _ in 0..<8 { if send.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(send.isHittable); send.tap()
		XCTAssertTrue(app.navigationBars["Jar payment"].waitForExistence(timeout: 5))
		let toggle = app.switches["jars-send-coinjoin"]
		XCTAssertTrue(toggle.exists); toggle.tap()
		XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "no direct payment is made")).firstMatch.exists)
		XCTAssertFalse(app.buttons["Review payment"].isEnabled)
		capture(app, "Jar send CoinJoin choice")
		toggle.tap()
		XCTAssertTrue(app.staticTexts["Direct payment. This transaction will not use CoinJoin."].exists)
		XCTAssertFalse(app.buttons["Review payment"].isEnabled, "Preview cannot prepare a live payment")
		app.buttons["Close"].tap()
		XCTAssertTrue(app.navigationBars["Jars"].waitForExistence(timeout: 5))
	}

	func testMakerPercentagesAndMarketHelpStayReadOnlyInPreview() {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-joinblaket-preview", "-appearance", "dark"]
		app.launch()
		XCTAssertTrue(app.navigationBars["Jars"].waitForExistence(timeout: 15))
		XCTAssertFalse(app.buttons["Percentage"].exists)
		let guide = app.buttons["jars-tool-guide"]
		for _ in 0..<10 { if guide.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(guide.isHittable)
		capture(app, "Jars earning overview")
		openJarsTool(app, "settings", "Maker settings")
		let percentage = app.buttons["Percentage"].firstMatch
		XCTAssertTrue(percentage.isHittable); percentage.tap()
		XCTAssertTrue(app.staticTexts["At 1,000,000 sats, your fee is 50 sats."].exists)
		let checks = app.buttons["Setup checks · 4 of 5"].firstMatch
		for _ in 0..<6 { if checks.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(checks.isHittable); checks.tap()
		XCTAssertTrue(app.otherElements["Maker setup"].exists)
		checks.tap()
		capture(app, "Maker settings page")
		app.navigationBars["Maker settings"].buttons.firstMatch.tap()
		openJarsTool(app, "market", "Market fees")
		XCTAssertTrue(app.textFields["Compare CoinJoin amount (sats)"].exists)
		XCTAssertFalse(app.buttons["Refresh market fees"].isEnabled, "Preview cannot contact a live watcher")
		capture(app, "Market comparison page")
		app.navigationBars["Market fees"].buttons.firstMatch.tap()
		openJarsTool(app, "settings", "Maker settings")
		XCTAssertTrue(app.staticTexts["At 1,000,000 sats, your fee is 50 sats."].exists, "Fee draft survives navigation")
		app.navigationBars["Maker settings"].buttons.firstMatch.tap()
		openJarsTool(app, "guide", "How earning works")
		XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "JoinBlaket’s default takers require a fidelity bond.")).firstMatch.exists)
	}
	private func openJarsTool(_ app: XCUIApplication, _ key: String, _ title: String) {
		let row = app.buttons["jars-tool-" + key]
		for _ in 0..<10 { if row.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(row.isHittable); row.tap()
		XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
	}

	func testBondWithdrawalKeepsSelectedValueFixedWithoutCoinJoin() {
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-joinblaket-preview", "-jam-bond-withdraw-preview", "-appearance", "dark"]
		app.launch()
		XCTAssertTrue(app.navigationBars["Jars"].waitForExistence(timeout: 15))
		openJarsTool(app, "bond", "Fidelity bond")
		let withdraw = app.buttons["Review withdrawal"]
		XCTAssertTrue(withdraw.waitForExistence(timeout: 5)); withdraw.tap()
		XCTAssertTrue(app.buttons["Review payment"].waitForExistence(timeout: 5))
		XCTAssertEqual(app.staticTexts["jars-withdraw-value"].label,"Bond value, 20,000 sats")
		XCTAssertTrue(app.textFields["XBT address"].exists)
		XCTAssertFalse(app.textFields["Amount (sats)"].exists)
		XCTAssertFalse(app.switches["jars-send-coinjoin"].exists)
		XCTAssertFalse(app.buttons["Review payment"].isEnabled)
		capture(app, "Bond withdrawal fixed input")
		app.buttons["Close"].tap()
	}
	func testBondFundingKeepsRegisteredAddressAndDateFixed() {
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-joinblaket-preview", "-jam-bond-funding-preview", "-appearance", "dark"]
		app.launch()
		XCTAssertTrue(app.navigationBars["Jars"].waitForExistence(timeout: 15))
		openJarsTool(app, "bond", "Fidelity bond")
		let fund = app.buttons["Fund from Apricot"]
		for _ in 0..<8 { if fund.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(fund.isHittable); fund.tap()
		XCTAssertTrue(app.buttons["Review payment"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.staticTexts["bcrt1qsyntheticrecipient"].exists)
		XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Unlocks 2099-12-01 at 00:00 UTC")).firstMatch.exists)
		XCTAssertFalse(app.textFields["XBT address"].exists)
		XCTAssertFalse(app.switches["jars-send-coinjoin"].exists)
		XCTAssertFalse(app.buttons["Review payment"].isEnabled)
		capture(app, "Bond funding fixed terms")
		app.buttons["Close"].tap()
		XCTAssertFalse(app.buttons["Review payment"].exists)
	}
	func testBondSetupKeepsLockDateAndNoFundingExplanationVisible() {
		continueAfterFailure = false
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-joinblaket-preview", "-appearance", "dark"]
		app.launch()
		XCTAssertTrue(app.navigationBars["Jars"].waitForExistence(timeout: 15))
		openJarsTool(app, "bond", "Fidelity bond")
		let review = app.buttons["Review bond address"].firstMatch
		for _ in 0..<8 { if review.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(review.exists)
		XCTAssertTrue(app.staticTexts["Unlocks on the first day at 00:00 UTC. Creating the address sends no funds."].exists)
		XCTAssertFalse(review.isEnabled, "The fixture must not contact a live Jam service")
		capture(app, "Bond setup compact")
		XCUIDevice.shared.orientation = .landscapeLeft
		assertWideContent(app)
		for _ in 0..<8 { if review.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(review.exists)
		capture(app, "Bond setup wide")
	}

	func testAssistanceHealthAndBackupStayReadableInCompactAndWideLayouts() {
		continueAfterFailure = false
		defer { XCUIDevice.shared.orientation = .portrait }
		for (flag, title, control) in [
			("-wallet-health-preview", "Wallet health", "Prepare support report"),
			("-backup-center-preview", "Backup & recovery", "backup-check"),
			("-payment-assistance-preview", "Transaction", "Review fee increase"),
			("-own-transfer-preview", "Send XBT", "Move to my other wallet")
		] {
			XCUIDevice.shared.orientation = .portrait
			let app = XCUIApplication()
			app.launchArguments = ["-build61-preview", flag, "-appearance", "dark"]
			app.launch()
			XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15))
			let button = app.buttons[control].firstMatch
			for _ in 0..<8 { if button.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
			XCTAssertTrue(button.exists)
			XCTAssertTrue(button.isHittable)
			capture(app, "Assistance compact " + title)
			XCUIDevice.shared.orientation = .landscapeLeft
			assertWideContent(app)
			XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10))
			for _ in 0..<8 { if button.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
			XCTAssertTrue(button.exists)
			XCTAssertTrue(button.isHittable)
			capture(app, "Assistance wide " + title)
			if flag == "-wallet-health-preview" {
				button.tap()
				let share = app.buttons["Share report…"].firstMatch
				for _ in 0..<8 { if share.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
				XCTAssertTrue(share.isHittable)
			} else if flag == "-backup-center-preview" {
				for (action, destination, field) in [
					("backup-save", "Save backup", "Prepare encrypted backup"),
					("backup-check", "Check backup", "Choose file to check…"),
					("backup-restore", "Restore backup", "Choose backup file…")
				] {
					app.buttons[action].tap()
					XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 10))
					XCTAssertTrue(app.buttons[field].waitForExistence(timeout: 10))
					capture(app, "Backup task " + destination)
					backButton(app, title: destination).tap()
					XCTAssertTrue(app.buttons["backup-save"].waitForExistence(timeout: 10))
				}
			}
			app.terminate()
		}
	}

	func testTabSelectionAndNestedBackRemainStable() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-wallet-shell-preview", "-appearance", "dark"]
		app.launch()
		let settings = primaryTab(app, "Settings")
		XCTAssertTrue(settings.waitForExistence(timeout: 15))
		settings.tap()
		XCTAssertTrue(settings.isSelected)
		let recovery = app.buttons["settings-recovery"]
		XCTAssertTrue(recovery.waitForExistence(timeout: 10))
		recovery.tap()
		let security = app.buttons["settings-security"]
		for _ in 0..<6 { if security.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(security.isHittable)
		security.tap()
		XCTAssertTrue(app.navigationBars["Wallet security"].waitForExistence(timeout: 10))
		primaryTab(app, "Jars").tap()
		XCTAssertTrue(primaryTab(app, "Jars").isSelected)
		XCTAssertTrue(app.navigationBars["Jars"].waitForExistence(timeout: 10))
		XCTAssertFalse(app.buttons["Kilojoin recovery"].exists)
		capture(app, "Jars primary navigation")
		primaryTab(app, "Wallet").tap()
		XCTAssertTrue(primaryTab(app, "Wallet").isSelected)
		XCTAssertTrue(app.staticTexts["Total balance"].waitForExistence(timeout: 10))
		settings.tap()
		XCTAssertTrue(app.navigationBars["Wallet security"].waitForExistence(timeout: 10))
		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertTrue(settings.isSelected)
		backButton(app, title: "Wallet security").tap()
		XCTAssertTrue(app.navigationBars["Security & recovery"].waitForExistence(timeout: 10))
		backButton(app, title: "Security & recovery").tap()
		XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
		XCTAssertTrue(settings.isSelected)
		capture(app, "Settings navigation wide")
		let experimental = app.buttons["settings-experimental"]
		for _ in 0..<6 { if experimental.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		experimental.tap()
		XCTAssertTrue(app.navigationBars["Experimental"].waitForExistence(timeout: 10))
		XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Kilojoin recovery'")).firstMatch.exists)
	}

	func testDashboardReflowsWithoutLosingBalanceVisibility() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-dashboard-preview", "-appearance", "dark"]
		app.launch()
		let hero = app.staticTexts["Total balance"]
		let account = app.staticTexts["On-chain"]
		XCTAssertTrue(hero.waitForExistence(timeout: 15))
		XCTAssertTrue(app.buttons["Send"].isHittable)
		XCTAssertTrue(app.buttons["Receive"].isHittable)
		// An unfolded display can already have room for columns in portrait.
		// Check both valid arrangements, then require wide layout and restoration.
		XCTAssertTrue(account.exists)
		let initiallyWide = account.frame.minX > hero.frame.maxX
		XCTAssertTrue(initiallyWide || account.frame.minY > hero.frame.maxY)
		app.buttons["Toggle balance visibility"].tap()
		XCUIDevice.shared.orientation = .landscapeLeft
		let sideBySide = NSPredicate { _, _ in
			account.exists && hero.exists && account.frame.minX > hero.frame.maxX
		}
		expectation(for: sideBySide, evaluatedWith: app)
		waitForExpectations(timeout: 10)
		XCTAssertTrue(app.staticTexts.matching(identifier: "Balance hidden").firstMatch.exists)
		capture(app, "Wallet wide")
		XCUIDevice.shared.orientation = .portrait
		let restored = NSPredicate { _, _ in
			guard account.exists && hero.exists else { return false }
			return initiallyWide ? account.frame.minX > hero.frame.maxX : account.frame.minY > hero.frame.maxY
		}
		expectation(for: restored, evaluatedWith: app)
		waitForExpectations(timeout: 10)
		XCTAssertTrue(app.staticTexts.matching(identifier: "Balance hidden").firstMatch.exists)
		capture(app, "Wallet compact")
	}

	func testWelcomeHasOneClearCreationPathAndKeepsTheName() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-appearance", "dark"]
		app.launch()
		let create = app.buttons["create-wallet"]
		XCTAssertTrue(create.waitForExistence(timeout: 15))
		XCTAssertFalse(app.staticTexts["Mobile wallet"].exists)
		XCTAssertTrue(app.staticTexts["Your keys. Your bitcoin."].exists)
		XCTAssertEqual(app.buttons.matching(identifier: "create-wallet").count, 1)
		let name = app.textFields["Wallet name"]
		name.tap(); name.typeText(" 2")
		let editedName = name.value as? String
		XCTAssertTrue(editedName?.contains("2") == true)
		app.buttons["wallet-name-done"].tap()
		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertEqual(name.value as? String, editedName)
		capture(app, "Welcome wide")
		XCUIDevice.shared.orientation = .portrait
		XCTAssertEqual(name.value as? String, editedName)
		capture(app, "Welcome compact")
		// Enter only the preparation sheet; never generate or display recovery words.
		create.tap()
		XCTAssertTrue(app.buttons["Generate 24 words"].waitForExistence(timeout: 10))
		XCTAssertTrue(app.buttons["Generate 24 words"].isEnabled)
		let seedScroll = app.scrollViews["seed-generation-page"]
		XCTAssertTrue(seedScroll.exists)
		for source in ["dice", "sensors", "system"] {
			let choice = app.buttons["seed-source-\(source)"]
			// Scroll toward this row only. A downward swipe at the top can
			// dismiss a compact sheet instead of scrolling its content.
			for _ in 0..<5 {
				let midpoint = CGPoint(x: choice.frame.midX, y: choice.frame.midY)
				let viewport = seedScroll.frame.insetBy(dx: 0, dy: 24)
				if viewport.contains(midpoint) && choice.isHittable { break }
				if midpoint.y < viewport.minY { seedScroll.swipeDown() }
				else { seedScroll.swipeUp() }
			}
			capture(app, "Seed source \(source) · no generation")
			XCTAssertTrue(choice.isHittable)
			choice.tap()
			XCTAssertEqual(app.buttons["Generate 24 words"].isEnabled, source == "system")
		}
		app.buttons["Cancel"].tap()
		XCTAssertTrue(create.waitForExistence(timeout: 5))
	}

	func testWelcomeRecoveryRemainsReachableWithLargeText() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		let app = XCUIApplication()
		app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
		app.launch()
		let create = app.buttons["create-wallet"]
		XCTAssertTrue(create.waitForExistence(timeout: 15))
		for _ in 0..<10 { if create.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(create.isHittable)
		let restore = app.buttons["import-seed-words"]
		for _ in 0..<10 { if restore.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(restore.isHittable)
		restore.tap()
		XCTAssertTrue(app.staticTexts["Import your seed"].waitForExistence(timeout: 10))
		app.buttons["import-back"].tap()
		XCTAssertFalse(app.staticTexts["Mobile wallet"].exists)
		let backup = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Restore a backup")).firstMatch
		for _ in 0..<10 { if backup.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(backup.isHittable)
		backup.tap()
		let bar = app.navigationBars["Restore backup"]
		XCTAssertTrue(bar.waitForExistence(timeout: 10))
		XCTAssertTrue(backButton(app, title: "Restore backup").isHittable)
		backButton(app, title: "Restore backup").tap()
	}

	func testNodeConnectionLabelsAndDraftSurviveRotation() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-node-connection-preview", "-appearance", "dark"]
		app.launch()
		let address = app.textFields["node-rest-address"]
		XCTAssertTrue(address.waitForExistence(timeout: 15))
		address.tap()
		address.typeText("https://node.example.invalid")
		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertEqual(address.value as? String, "https://node.example.invalid")
		XCTAssertTrue(app.staticTexts["REST address"].exists)
		XCTAssertTrue(app.staticTexts["Privacy & verification"].exists)
		capture(app, "Node connection wide")
		XCUIDevice.shared.orientation = .portrait
		XCTAssertEqual(address.value as? String, "https://node.example.invalid")
		capture(app, "Node connection compact")
	}

	func testBridgeStatusIsVisibleOnEntryAndBothDirections() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-lightning-balance-preview", "-appearance", "dark"]
		app.launch()
		let entry = app.buttons["lightning-open-bridge"]
		XCTAssertTrue(entry.waitForExistence(timeout: 15))
		entry.tap()
		let badge = app.descendants(matching: .any).matching(identifier: "bridge-service-status").firstMatch
		XCTAssertTrue(badge.waitForExistence(timeout: 10))
		let openedAt = Date()
		app.buttons["bridge-open-pay"].tap()
		XCTAssertTrue(app.navigationBars["Pay Spamcoin (BTC)"].waitForExistence(timeout: 10))
		XCTAssertTrue(badge.waitForExistence(timeout: 10))
		XCTAssertLessThan(Date().timeIntervalSince(openedAt), 30, "Bridge navigation must not stall the UI event loop")
		XCTAssertTrue(badge.label.hasPrefix("Bridge service:"))
		capture(app, "Bridge send status compact")
		// Duo places Back in a separate toolbar; older iOS exposes the
		// navigation-bar button with the preceding page's accessibility label.
		let toolbarBack = app.descendants(matching: .any).matching(identifier: "BackButton").firstMatch
		let back = toolbarBack.exists ? toolbarBack : app.navigationBars["Pay Spamcoin (BTC)"].buttons["Paperclip Bridge"]
		XCTAssertTrue(back.waitForExistence(timeout: 5))
		XCTAssertTrue(back.isHittable)
		back.tap()
		XCTAssertTrue(app.buttons["bridge-open-receive"].waitForExistence(timeout: 10))
		app.buttons["bridge-open-receive"].tap()
		XCTAssertTrue(badge.waitForExistence(timeout: 10))
		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertTrue(badge.waitForExistence(timeout: 10))
		capture(app, "Bridge receive status wide")
		// Availability may be unknown on an offline test host. No quote or payment is created.
	}

	// Open a foldable simulator in Device Hub before testing its wide layout.
	func testLightningReflows() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-lightning-balance-preview", "-appearance", "dark"]
		app.launch()
		let balance = app.staticTexts["Funds in active channels"]
		let bridge = app.staticTexts["Paperclip Bridge"]
		XCTAssertTrue(balance.waitForExistence(timeout: 15))
		XCTAssertGreaterThan(bridge.frame.minY, balance.frame.maxY)
		XCUIDevice.shared.orientation = .landscapeLeft
		expectation(for: NSPredicate { _, _ in
			guard bridge.exists, balance.exists else { return false }
			let primary = balance.frame, secondary = bridge.frame
			guard primary.width > 0, primary.height > 0, secondary.width > 0, secondary.height > 0 else { return false }
			return secondary.minX > primary.maxX
		}, evaluatedWith: app)
		waitForExpectations(timeout: 10)
		capture(app, "Lightning wide")
	}

	func testAccessibilityTextStacksWideLayout() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .landscapeLeft
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-lightning-balance-preview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
		app.launch()
		let balance = app.staticTexts["Funds in active channels"]
		let bridge = app.staticTexts["Paperclip Bridge"]
		XCTAssertTrue(balance.waitForExistence(timeout: 15))
		XCTAssertGreaterThan(bridge.frame.minY, balance.frame.maxY)
		capture(app, "Lightning accessibility")
	}

	func testPendingReceiptDoesNotCelebrateCompletion() {
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-receipt-preview"]
		app.launch()
		XCTAssertTrue(app.staticTexts["Ark deposit started"].waitForExistence(timeout: 15))
		XCTAssertFalse(app.staticTexts["Payment completed"].exists)
		XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'registration with the Ark server'")).firstMatch.exists)
		capture(app, "Deposit pending, not completed")
	}

	func testCompletedReceiptHasClearSuccessState() {
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-receipt-preview", "-completed-receipt-preview"]
		app.launch()
		XCTAssertTrue(app.staticTexts["Payment completed"].waitForExistence(timeout: 15))
		XCTAssertFalse(app.staticTexts["Payment pending"].exists)
		XCTAssertTrue(app.buttons["Done"].isHittable)
		capture(app, "Verified payment complete")
	}

	func testLiveStartOSLANConnections() throws {
		try XCTSkipIf(ProcessInfo.processInfo.environment["PAPERCLIP_LIVE_NODE_TESTS"] != "1", "Requires private simulator input and explicit live-test opt-in")
		continueAfterFailure = false
		for fixture in ["cln-lan", "lnd-lan"] {
			let app = XCUIApplication()
			app.launchArguments = ["-build61-preview", "-node-connection-preview", "-live-node-case", fixture]
			app.launch()
			let verify = app.buttons["Verify and save connection"]
			XCTAssertTrue(verify.waitForExistence(timeout: 15))
			for _ in 0..<8 { if verify.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
			XCTAssertTrue(verify.isHittable)
			verify.tap()
			XCTAssertTrue(app.descendants(matching: .any)["lightning-node-connected"].firstMatch.waitForExistence(timeout: 90))
			XCTAssertTrue(app.buttons["Refresh Lightning balance"].exists)
			app.buttons["Refresh Lightning balance"].tap()
			XCTAssertTrue(app.descendants(matching: .any)["lightning-node-connected"].firstMatch.exists)
			app.terminate()
		}
	}

	private func primaryTab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
		// Duo puts these buttons in a side rail instead of an XCUI tab bar.
		app.buttons[name]
	}

	private func backButton(_ app: XCUIApplication, title: String) -> XCUIElement {
		let toolbarBack = app.descendants(matching: .any).matching(identifier: "BackButton").firstMatch
		return toolbarBack.exists ? toolbarBack : app.navigationBars[title].buttons.firstMatch
	}

	private func assertWideContent(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
		// Duo's application frame is not the active display viewport. Check the
		// scroll viewport, which must reflow when the active display rotates.
		let wide = NSPredicate { _, _ in
			guard app.scrollViews.firstMatch.exists else { return false }
			let content = app.scrollViews.firstMatch.frame
			return content.width > content.height && content.height > 0
		}
		XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: wide, object: app)], timeout: 10) == .completed,
			"Expected wide content, got \(app.scrollViews.firstMatch.frame)", file: file, line: line)
	}

	private func capture(_ app: XCUIApplication, _ name: String) {
		// These captures are synthetic fixtures only, never authenticated node tests.
		let tree = XCTAttachment(string: app.debugDescription)
		tree.name = name + " · accessibility layout"
		tree.lifetime = .keepAlways
		add(tree)
		// The unfolded Duo uses a second display; main alone can be powered off.
		// Whole-screen captures also avoid stale element bounds after rotation.
		for (index, screen) in XCUIScreen.screens.enumerated() {
			let attachment = XCTAttachment(screenshot: screen.screenshot())
			attachment.name = "\(name) · screen \(index + 1)"
			attachment.lifetime = .keepAlways
			add(attachment)
		}
	}
}
