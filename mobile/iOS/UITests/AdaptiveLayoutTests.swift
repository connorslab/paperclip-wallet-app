import XCTest

/// Synthetic fixtures only: no wallet credentials, synchronization or payments.
final class AdaptiveLayoutTests: XCTestCase {
	func testSendReviewIsOneStepAndEditingPreservesRecipient() {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-ark-fee-preview", "-appearance", "dark"]
		app.launch()
		let confirm = app.buttons["Confirm payment"]
		XCTAssertTrue(confirm.waitForExistence(timeout: 15))
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

	func testBondSetupKeepsLockDateAndNoFundingExplanationVisible() {
		continueAfterFailure = false
		defer { XCUIDevice.shared.orientation = .portrait }
		let app = XCUIApplication()
		app.launchArguments = ["-build61-preview", "-joinblaket-preview", "-appearance", "dark"]
		app.launch()
		XCTAssertTrue(app.navigationBars["Jars"].waitForExistence(timeout: 15))
		let setup = app.buttons["Set up a fidelity bond"].firstMatch
		for _ in 0..<10 { if setup.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(setup.isHittable); setup.tap()
		let review = app.buttons["Review bond address"].firstMatch
		for _ in 0..<8 { if review.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
		XCTAssertTrue(review.exists)
		XCTAssertTrue(app.staticTexts["Unlocks on the first day at 00:00 UTC. Creating the address sends no funds."].exists)
		XCTAssertFalse(review.isEnabled, "The fixture must not contact a live Jam service")
		capture(app, "Bond setup compact")
		XCUIDevice.shared.orientation = .landscapeLeft
		let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
		XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 10) == .completed)
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
			let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
			XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 10) == .completed)
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
					app.navigationBars[destination].buttons.firstMatch.tap()
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
		let settings = app.tabBars.buttons["Settings"]
		XCTAssertTrue(settings.waitForExistence(timeout: 15))
		settings.tap()
		XCTAssertTrue(settings.isSelected)
		let recovery = app.buttons["settings-recovery"]
		XCTAssertTrue(recovery.waitForExistence(timeout: 10))
		recovery.tap()
		let security = app.buttons["settings-security"]
		for _ in 0..<6 { if security.isHittable { break }; app.swipeUp() }
		XCTAssertTrue(security.isHittable)
		security.tap()
		XCTAssertTrue(app.navigationBars["Wallet security"].waitForExistence(timeout: 10))
		app.tabBars.buttons["Jars"].tap()
		XCTAssertTrue(app.tabBars.buttons["Jars"].isSelected)
		XCTAssertTrue(app.navigationBars["Jars"].waitForExistence(timeout: 10))
		XCTAssertFalse(app.buttons["Kilojoin recovery"].exists)
		capture(app, "Jars primary navigation")
		app.tabBars.buttons["Wallet"].tap()
		XCTAssertTrue(app.tabBars.buttons["Wallet"].isSelected)
		XCTAssertTrue(app.staticTexts["Total balance"].waitForExistence(timeout: 10))
		settings.tap()
		XCTAssertTrue(app.navigationBars["Wallet security"].waitForExistence(timeout: 10))
		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertTrue(settings.isSelected)
		app.navigationBars["Wallet security"].buttons.firstMatch.tap()
		XCTAssertTrue(app.navigationBars["Security & recovery"].waitForExistence(timeout: 10))
		app.navigationBars["Security & recovery"].buttons.firstMatch.tap()
		XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
		XCTAssertTrue(settings.isSelected)
		capture(app, "Settings navigation wide")
		let experimental = app.buttons["settings-experimental"]
		for _ in 0..<6 { if experimental.isHittable { break }; app.swipeUp() }
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
		XCTAssertGreaterThan(account.frame.minY, hero.frame.maxY)
		app.buttons["Toggle balance visibility"].tap()
		XCUIDevice.shared.orientation = .landscapeLeft
		let sideBySide = NSPredicate { _, _ in account.frame.minX > hero.frame.maxX }
		expectation(for: sideBySide, evaluatedWith: app)
		waitForExpectations(timeout: 10)
		XCTAssertTrue(app.staticTexts.matching(identifier: "Balance hidden").firstMatch.exists)
		capture(app, "Wallet wide")
		XCUIDevice.shared.orientation = .portrait
		let stacked = NSPredicate { _, _ in account.frame.minY > hero.frame.maxY }
		expectation(for: stacked, evaluatedWith: app)
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
	}

	func testWelcomeRecoveryRemainsReachableWithLargeText() {
		continueAfterFailure = false
		XCUIDevice.shared.orientation = .portrait
		let app = XCUIApplication()
		app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
		app.launch()
		let create = app.buttons["create-wallet"]
		XCTAssertTrue(create.waitForExistence(timeout: 15))
		for _ in 0..<10 { if create.isHittable { break }; app.swipeUp() }
		XCTAssertTrue(create.isHittable)
		let restore = app.buttons["import-seed-words"]
		for _ in 0..<10 { if restore.isHittable { break }; app.swipeUp() }
		XCTAssertTrue(restore.isHittable)
		restore.tap()
		XCTAssertTrue(app.staticTexts["Import your seed"].waitForExistence(timeout: 10))
		app.buttons["import-back"].tap()
		XCTAssertFalse(app.staticTexts["Mobile wallet"].exists)
		let backup = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Restore a backup")).firstMatch
		for _ in 0..<10 { if backup.isHittable { break }; app.swipeUp() }
		XCTAssertTrue(backup.isHittable)
		backup.tap()
		let bar = app.navigationBars["Restore backup"]
		XCTAssertTrue(bar.waitForExistence(timeout: 10))
		XCTAssertTrue(bar.buttons.firstMatch.isHittable)
		bar.buttons.firstMatch.tap()
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
			for _ in 0..<8 { if verify.isHittable { break }; app.swipeUp() }
			XCTAssertTrue(verify.isHittable)
			verify.tap()
			XCTAssertTrue(app.descendants(matching: .any)["lightning-node-connected"].firstMatch.waitForExistence(timeout: 90))
			XCTAssertTrue(app.buttons["Refresh Lightning balance"].exists)
			app.buttons["Refresh Lightning balance"].tap()
			XCTAssertTrue(app.descendants(matching: .any)["lightning-node-connected"].firstMatch.exists)
			app.terminate()
		}
	}

	private func capture(_: XCUIApplication, _ name: String) {
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
