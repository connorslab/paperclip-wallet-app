import AppKit
import Foundation
import Darwin

private struct RuntimeConfiguration: Decodable {
	let pythonExecutable: String
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

final class Launcher: NSObject, NSApplicationDelegate {
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
		let stack = NSStackView(views: [icon, title, status, progress, action, note, preview])
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

	private func start() {
		guard helper?.isRunning != true else { return }
		ready = false
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
			var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Paperclip Preview", isDirectory: true)
			// QA is always explicit; production wallet directories are never searched.
			if let index = CommandLine.arguments.firstIndex(of: "--qa-root") {
				guard CommandLine.arguments.count > index + 1, CommandLine.arguments[index + 1].hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
				root = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
			}
			let process = Process(), incoming = Pipe(), outgoing = Pipe()
			process.executableURL = URL(fileURLWithPath: configuration.pythonExecutable)
			process.arguments = ["-I", resources.appendingPathComponent("launcher_entry.py").path,
				"--binary", executables.appendingPathComponent("paperclip-walletd").path, "--root", root.path]
			if let jamPython = configuration.jamPythonExecutable {
				process.arguments! += ["--jam-python", jamPython, "--jam-entry", resources.appendingPathComponent("jam-runtime/desktop-entry.py").path]
			}
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
			case "ready":
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
		ready = false
		status.stringValue = message
		progress.stopAnimation(nil)
		progress.isHidden = true
		action.title = "Try Again"
		action.isEnabled = true
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
		try? input?.fileHandleForWriting.write(contentsOf: Data("{\"action\":\"quit\"}\n".utf8))
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
