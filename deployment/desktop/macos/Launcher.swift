import AppKit
import Foundation
import Darwin

private struct RuntimeConfiguration: Decodable {
	let pythonExecutable: String?
	let bundledHelpers: Bool?
	let bundledTor: Bool?
	let jamPythonExecutable: String?
}

private struct BridgeEvent: Decodable {
	let event: String
	let message: String?
	let url: String?
	let recoveryRequired: Bool?

	enum CodingKeys: String, CodingKey {
		case event, message, url
		case recoveryRequired = "recovery_required"
	}
}

final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
	private var window: NSWindow!
	private let status = NSTextField(wrappingLabelWithString: "Starting your wallet…")
	private let progress = NSProgressIndicator()
	private let action = NSButton(title: "Open Wallet", target: nil, action: nil)
	private var helper: Process?
	private var input: Pipe?
	private var output: Pipe?
	private var buffer = Data()
	private var ready = false
	private var quitting = false
	private var failedMessage: String?
	private var setupWindow: NSWindow?
	private var setupFields: [String: NSTextField] = [:]
	private let setupTor = NSButton(checkboxWithTitle: "Use Tor", target: nil, action: nil)
	private let setupMessage = NSTextField(wrappingLabelWithString: "")
	private let setupSave = NSButton(title: "Verify and save", target: nil, action: nil)
	private let setupLater = NSButton(title: "Set up Jars later", target: nil, action: nil)
	private var setupCA = ""
	private var replacingNode = false
	private var manageRequested = false
	private var hasJars = false
	private let nodeSettings = NSButton(title: "Jars node settings…", target: nil, action: nil)

	func applicationDidFinishLaunching(_ notification: Notification) {
		let applicationMenu = NSMenu()
		let item = NSMenuItem()
		applicationMenu.addItem(item)
		let menu = NSMenu()
		menu.addItem(withTitle: "Quit Paperclip Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		item.submenu = menu
		NSApp.mainMenu = applicationMenu
		window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
			styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
		window.title = "Paperclip Preview"
		window.isReleasedWhenClosed = false
		let icon = NSImageView(image: NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Paperclip")!)
		icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .medium)
		icon.contentTintColor = .systemOrange
		let title = NSTextField(labelWithString: "Your wallet, on your Mac")
		title.font = .systemFont(ofSize: 23, weight: .semibold)
		status.alignment = .center
		status.textColor = .secondaryLabelColor
		progress.style = .spinning
		progress.controlSize = .small
		progress.startAnimation(nil)
		action.target = self
		action.action = #selector(openWallet)
		action.bezelStyle = .rounded
		action.controlSize = .large
		action.keyEquivalent = "\r"
		action.isEnabled = false
		let note = NSTextField(wrappingLabelWithString: "Keep this window open while using your wallet. Quitting stops the local wallet.")
		note.font = .systemFont(ofSize: 12)
		note.textColor = .secondaryLabelColor
		note.alignment = .center
		let preview = NSTextField(labelWithString: "Development preview")
		preview.font = .systemFont(ofSize: 11)
		preview.textColor = .tertiaryLabelColor
		nodeSettings.target = self; nodeSettings.action = #selector(manageNode)
		nodeSettings.bezelStyle = .rounded; nodeSettings.isEnabled = false
		let stack = NSStackView(views: [icon, title, status, progress, action, nodeSettings, note, preview])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 14
		stack.translatesAutoresizingMaskIntoConstraints = false
		window.contentView!.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
			stack.widthAnchor.constraint(equalToConstant: 380),
			status.widthAnchor.constraint(equalTo: stack.widthAnchor),
			note.widthAnchor.constraint(equalTo: stack.widthAnchor),
		])
		window.center()
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		start()
	}

	private func start(manage: Bool = false) {
		guard helper?.isRunning != true else { return }
		ready = false
		nodeSettings.isEnabled = false
		failedMessage = nil
		buffer.removeAll()
		action.title = "Open Wallet"
		action.isEnabled = false
		status.stringValue = "Starting your wallet…"
		progress.isHidden = false
		progress.startAnimation(nil)
		do {
			guard let resources = Bundle.main.resourceURL, let executables = Bundle.main.executableURL?.deletingLastPathComponent() else { throw CocoaError(.fileNoSuchFile) }
			let configuration = try JSONDecoder().decode(RuntimeConfiguration.self, from: Data(contentsOf: resources.appendingPathComponent("runtime.json")))
			hasJars = configuration.bundledHelpers == true || configuration.jamPythonExecutable != nil
			nodeSettings.isHidden = !hasJars
			var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Paperclip Preview", isDirectory: true)
			// QA is always explicit; production wallet directories are never searched.
			if let index = CommandLine.arguments.firstIndex(of: "--qa-root") {
				guard CommandLine.arguments.count > index + 1, CommandLine.arguments[index + 1].hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
				root = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
			}
			let process = Process(), incoming = Pipe(), outgoing = Pipe()
			if configuration.bundledHelpers == true {
				let helpers = resources.deletingLastPathComponent().appendingPathComponent("Helpers")
				process.executableURL = helpers.appendingPathComponent("PaperclipHelper.app/Contents/MacOS/PaperclipHelper")
				process.arguments = ["--binary", executables.appendingPathComponent("paperclip-walletd").path, "--root", root.path,
					"--jam-executable", helpers.appendingPathComponent("PaperclipJars.app/Contents/MacOS/PaperclipJars").path]
			} else if let python = configuration.pythonExecutable {
				process.executableURL = URL(fileURLWithPath: python)
				process.arguments = ["-I", "-B", resources.appendingPathComponent("launcher_entry.py").path,
					"--binary", executables.appendingPathComponent("paperclip-walletd").path, "--root", root.path]
				if let jamPython = configuration.jamPythonExecutable {
					process.arguments! += ["--jam-python", jamPython, "--jam-entry", resources.appendingPathComponent("jam-runtime/desktop-entry.py").path]
				}
			} else { throw CocoaError(.fileNoSuchFile) }
			if configuration.bundledTor == true {
				process.arguments! += ["--tor-runtime", resources.appendingPathComponent("PaperclipTor").path]
			}
			process.arguments! += [manage ? "--manage-node" : "--guided-setup"]
			process.environment = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR", "LANG"].contains($0.key) }
			process.standardInput = incoming
			process.standardOutput = outgoing
			process.standardError = FileHandle.nullDevice
			helper = process
			input = incoming
			output = outgoing
			try process.run()
			// One reader preserves event order, including errors written just before
			// exit. Waiting for the helper never blocks the AppKit main thread.
			DispatchQueue.global(qos: .userInitiated).async { [weak self] in
				while true {
					let data = outgoing.fileHandleForReading.availableData
					if data.isEmpty { break }
					DispatchQueue.main.async { self?.consume(data, from: process) }
				}
				process.waitUntilExit()
				DispatchQueue.main.async {
					guard let self = self, self.helper === process else { return }
					self.releaseHelper()
					if self.quitting { NSApp.reply(toApplicationShouldTerminate: true); return }
					if self.manageRequested && self.failedMessage == nil && process.terminationStatus == 0 {
						self.manageRequested = false; self.start(manage: true); return
					}
					self.manageRequested = false
					self.showFailure(self.failedMessage ?? "Your wallet stopped. You can open it again.")
				}
			}
		} catch {
			releaseHelper()
			showFailure("Paperclip could not start. Check that this preview includes its required runtime.")
		}
	}

	private func releaseHelper() {
		try? input?.fileHandleForWriting.close()
		try? output?.fileHandleForReading.close()
		input = nil
		output = nil
		helper = nil
	}

	private func consume(_ data: Data, from process: Process) {
		guard helper === process, !quitting else { return }
		buffer.append(data)
		guard buffer.count <= 8192 else { stopAfterProtocolError(); return }
		while let newline = buffer.firstIndex(of: 10) {
			let line = buffer.prefix(upTo: newline)
			guard let event = try? JSONDecoder().decode(BridgeEvent.self, from: line) else { stopAfterProtocolError(); return }
			buffer.removeSubrange(...newline)
			switch event.event {
			case "setup": replacingNode = false; showSetup()
			case "setup_change": replacingNode = true; showSetup()
			case "setup_progress": setupMessage.stringValue = event.message ?? "Checking your connection…"
			case "setup_error":
				setupMessage.stringValue = event.message ?? "The node could not be verified."
				setupSave.isEnabled = true
				setupLater.title = replacingNode ? "Keep saved connection" : "Set up Jars later"
			case "setup_complete": hideSetup()
			case "ready":
				nodeSettings.isEnabled = hasJars
				ready = true
				let recovery = event.recoveryRequired == true
				status.stringValue = recovery
					? "Your previous session did not close cleanly. Check Activity before making another payment."
					: "Ready when you are."
				action.title = recovery ? "Review Wallet" : "Open Wallet"
				progress.stopAnimation(nil)
				progress.isHidden = true
				action.isEnabled = true
			case "open":
				guard let text = event.url, let parts = URLComponents(string: text), parts.scheme == "http", parts.host == "127.0.0.1",
					let port = parts.port, (1...65535).contains(port), parts.path == "/", parts.query == nil,
					parts.user == nil, parts.password == nil, let fragment = parts.fragment,
					fragment.range(of: "^desktop-handoff=[A-Za-z0-9_-]{44}$", options: .regularExpression) != nil,
					let url = parts.url else { stopAfterProtocolError(); return }
				status.stringValue = NSWorkspace.shared.open(url) ? "Your wallet is open in your browser." : "The browser could not open. Try Open Wallet again."
				action.isEnabled = true
			case "error":
				failedMessage = event.message ?? "The wallet could not complete that action."
				status.stringValue = failedMessage!
				action.isEnabled = ready
			case "stopped": break
			default: stopAfterProtocolError(); return
			}
		}
	}

	private func stopAfterProtocolError() {
		failedMessage = "The desktop connection was interrupted. Open Paperclip again."
		action.isEnabled = false
		try? input?.fileHandleForWriting.close()
		if let process = helper, process.isRunning { process.terminate() }
	}

	private func showFailure(_ message: String) {
		nodeSettings.isEnabled = hasJars
		hideSetup()
		ready = false
		status.stringValue = message
		progress.stopAnimation(nil)
		progress.isHidden = true
		action.title = "Try Again"
		action.isEnabled = true
	}

	private func showSetup() {
		guard setupWindow == nil else { return }
		progress.stopAnimation(nil); progress.isHidden = true
		status.stringValue = "Connect an XBT node to host Jars on this Mac."
		let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 550),
			styleMask: [.titled, .closable], backing: .buffered, defer: false)
		panel.title = "Set up Jars"; panel.isReleasedWhenClosed = false; panel.delegate = self
		setupWindow = panel; setupCA = ""; setupFields.removeAll()
		let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
		stack.translatesAutoresizingMaskIntoConstraints = false
		func label(_ text: String, size: CGFloat = 13) {
			let value = NSTextField(wrappingLabelWithString: text); value.font = .systemFont(ofSize: size)
			stack.addArrangedSubview(value); value.widthAnchor.constraint(equalToConstant: 404).isActive = true
		}
		label(replacingNode ? "Change your Jars node" : "Your Jars, on this Mac", size: 23)
		label(replacingNode ? "Enter the replacement connection. Your Jars wallets and payment history stay intact." : "Connect your XBT node. Your Jars wallet stays separate from your main wallet.")
		for (key, title) in [("endpoint", "Node RPC address"), ("username", "RPC username"), ("password", "RPC password")] {
			label(title)
			let field: NSTextField = key == "password" ? NSSecureTextField() : NSTextField()
			field.font = .systemFont(ofSize: 14); field.controlSize = .large
			field.setAccessibilityLabel(title); setupFields[key] = field; stack.addArrangedSubview(field)
			field.widthAnchor.constraint(equalToConstant: 404).isActive = true
		}
		setupTor.state = .off; stack.addArrangedSubview(setupTor)
		let certificate = NSButton(title: "Add certificate (optional)", target: self, action: #selector(chooseSetupCertificate))
		certificate.bezelStyle = .rounded; stack.addArrangedSubview(certificate)
		setupMessage.stringValue = "Your connection is verified before it is saved."
		setupMessage.widthAnchor.constraint(equalToConstant: 404).isActive = true; stack.addArrangedSubview(setupMessage)
		setupSave.target = self; setupSave.action = #selector(saveSetup); setupSave.bezelStyle = .rounded
		setupSave.title = replacingNode ? "Review change" : "Verify and save"
		setupSave.controlSize = .large; setupSave.isEnabled = true; setupSave.keyEquivalent = "\r"
		setupLater.target = self; setupLater.action = #selector(deferSetup); setupLater.bezelStyle = .rounded
		setupLater.title = replacingNode ? "Keep saved connection" : "Set up Jars later"
		stack.addArrangedSubview(setupSave); stack.addArrangedSubview(setupLater)
		panel.contentView!.addSubview(stack)
		NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 28),
			stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24)])
		window.addChildWindow(panel, ordered: .above); panel.center(); panel.makeKeyAndOrderFront(nil)
		panel.makeFirstResponder(setupFields["endpoint"])
	}

	private func hideSetup() {
		guard let panel = setupWindow else { return }
		setupFields["password"]?.stringValue = ""; setupFields.removeAll(); setupCA = ""
		window.removeChildWindow(panel); panel.orderOut(nil); setupWindow = nil
	}

	@objc private func chooseSetupCertificate() {
		guard let panel = setupWindow else { return }
		let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
		picker.beginSheetModal(for: panel) { [weak self] result in
			guard let self = self, result == .OK, let url = picker.url else { return }
			do {
				let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
				let data = try file.read(upToCount: 65537) ?? Data()
				guard data.count <= 65536, let text = String(data: data, encoding: .ascii),
					text.contains("BEGIN CERTIFICATE"), !text.contains("PRIVATE KEY") else { throw CocoaError(.fileReadCorruptFile) }
				self.setupCA = text; self.setupMessage.stringValue = "Certificate selected."
			} catch { self.setupMessage.stringValue = "Choose a public CA certificate, not a private key." }
		}
	}

	@objc private func saveSetup() {
		guard setupSave.isEnabled, setupWindow != nil else { return }
		var settings: [String: Any] = setupFields.mapValues { $0.stringValue }
		settings["tor"] = setupTor.state == .on; settings["ca_pem"] = setupCA
		if replacingNode {
			let review = NSAlert(); review.messageText = "Review node change"
			let endpoint = settings["endpoint"] as? String ?? ""
			let username = settings["username"] as? String ?? ""
			let tor = setupTor.state == .on ? "On" : "Off"
			let certificate = setupCA.isEmpty ? "None" : "Selected"
			review.informativeText = "Node: \(endpoint)\nRPC username: \(username)\nTor: \(tor)\nCustom certificate: \(certificate)\n\nVerify and replace the saved connection? Wallets and history are kept."
			review.addButton(withTitle: "Verify and replace"); review.addButton(withTitle: "Cancel")
			guard review.runModal() == .alertFirstButtonReturn else { return }
		}
		setupFields["password"]?.stringValue = ""
		setupSave.isEnabled = false; setupLater.title = "Cancel setup"
		setupMessage.stringValue = "Checking your connection…"
		var request: [String: Any] = ["action": replacingNode ? "replace_jars" : "configure_jars", "settings": settings]
		if replacingNode { request["confirmed"] = true }
		sendSetup(request)
	}

	private func sendSetup(_ value: [String: Any]) {
		do {
			var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
			guard data.count <= 96 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
			// Large public CA files must not block AppKit while the pipe drains.
			guard let writer = input?.fileHandleForWriting, let owner = helper else { throw CocoaError(.fileNoSuchFile) }
			let payload = data
			DispatchQueue.global(qos: .userInitiated).async { [weak self] in
				do { try writer.write(contentsOf: payload) }
				catch {
					DispatchQueue.main.async {
						guard let self = self, self.helper === owner, !self.quitting else { return }
						self.stopAfterProtocolError()
					}
				}
			}
		} catch { stopAfterProtocolError() }
	}

	@objc private func deferSetup() {
		if setupSave.isEnabled {
			sendSetup(["action": "skip_jars"]); hideSetup()
			status.stringValue = "Starting your wallet…"; progress.isHidden = false; progress.startAnimation(nil)
		} else {
			failedMessage = "Setup was cancelled. Saving may have completed. Reopen Jars node settings to check the saved connection."
			try? input?.fileHandleForWriting.close(); hideSetup(); status.stringValue = "Cancelling setup…"
		}
	}

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		if sender === setupWindow { deferSetup(); return false }
		return true
	}

	@objc private func manageNode() {
		guard hasJars, nodeSettings.isEnabled, !quitting else { return }
		if helper?.isRunning != true { start(manage: true); return }
		let review = NSAlert(); review.messageText = "Jars node settings"
		review.informativeText = "Close the local wallet to change its Jars node? Check any payment in progress before continuing."
		review.addButton(withTitle: "Close wallet and continue"); review.addButton(withTitle: "Cancel")
		guard review.runModal() == .alertFirstButtonReturn else { return }
		manageRequested = true; ready = false; nodeSettings.isEnabled = false; action.isEnabled = false
		status.stringValue = "Closing your wallet safely…"
		try? input?.fileHandleForWriting.close()
	}

	@objc private func openWallet() {
		guard ready else { start(); return }
		action.isEnabled = false
		status.stringValue = "Opening your wallet…"
		do { try input?.fileHandleForWriting.write(contentsOf: Data("{\"action\":\"open\"}\n".utf8)) }
		catch { stopAfterProtocolError() }
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		guard let process = helper, process.isRunning else { return .terminateNow }
		if quitting { return .terminateLater }
		quitting = true
		action.isEnabled = false
		status.stringValue = "Closing your wallet safely…"
		// EOF cancels verification and closes the owned session without racing a large setup write.
		hideSetup()
		try? input?.fileHandleForWriting.close()
		DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
			if process.isRunning { process.terminate() }
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
			if process.isRunning { kill(process.processIdentifier, SIGKILL) }
		}
		return .terminateLater
	}
}

let app = NSApplication.shared
let launcher = Launcher()
app.setActivationPolicy(.regular)
app.delegate = launcher
app.run()
