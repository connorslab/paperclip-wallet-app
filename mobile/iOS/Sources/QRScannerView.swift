import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    let onScan: (String) -> Void
    @State private var allowed = false
    @State private var error = ""
    @State private var scannerID = UUID()
    var body: some View {
        NavigationStack {
            ZStack {
                PaperclipTheme.navy.ignoresSafeArea()
                if allowed {
                    CameraScanner(active: scene == .active) { value in onScan(value); dismiss() } onError: { error = $0 }
                        .id(scannerID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .bottom)
                }
                VStack {
                    Text("Scan a payment QR code. Review the recipient and amount before sending.")
                        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
                    Spacer()
                    if !error.isEmpty {
                        Text(error).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
                        if allowed {
                            Button("Retry camera") { error = ""; scannerID = UUID() }.buttonStyle(.borderedProminent)
                        }
                        if !allowed, let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Open camera settings", destination: url).padding()
                        }
                    }
                }
            }.navigationTitle("Scan payment").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { dismiss() } }
                .task(id: scene) {
                    guard scene == .active else { return }
                    switch AVCaptureDevice.authorizationStatus(for: .video) {
                    case .authorized: allowed = true
                    case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
                    default: allowed = false
                    }
                    if allowed { error = "" }
                    if !allowed { error = "Allow camera access in Settings to scan a QR code. You can also paste a payment request." }
                }
        }
    }
}

private struct CameraScanner: UIViewControllerRepresentable {
    let active: Bool
    let onScan: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan; controller.onError = onError
        return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) { controller.setActive(active) }
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "paperclip.camera")
    private var configured = false
    private var visible = false
    private var active = true
    private var delivered = false
    private var previewCheck: DispatchWorkItem?
    override func loadView() {
        view = CameraPreviewView()
        let preview = (view as! CameraPreviewView).preview
        preview.session = session
        preview.videoGravity = .resizeAspectFill
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(interrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(runtimeError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
        center.addObserver(self, selector: #selector(started), name: AVCaptureSession.didStartRunningNotification, object: session)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func interrupted(_ notification: Notification) {
        let code = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
        let reason = code.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
        let message: String
        switch reason {
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            message = "iOS paused the camera while another video window is active. Close Picture-in-Picture, then retry."
        case .videoDeviceInUseByAnotherClient, .audioDeviceInUseByAnotherClient:
            message = "Another app is using the camera or capture hardware. Close its camera or video session, then retry."
        case .videoDeviceNotAvailableInBackground:
            message = "Return to Paperclip to resume the camera."
        case .videoDeviceNotAvailableDueToSystemPressure:
            message = "iOS paused the camera because the device is under load or too warm. Try again after it cools down."
        default:
            message = "iOS interrupted the camera (reason \(code.map(String.init) ?? "unknown")). Close other video windows, then retry."
        }
        DispatchQueue.main.async { [weak self] in self?.previewCheck?.cancel(); self?.onError?(message) }
    }
    @objc private func interruptionEnded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visible, self.active, !self.delivered else { return }
            self.onError?(""); self.setActive(true); self.checkPreview()
        }
    }
    @objc private func runtimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let message = error?.localizedDescription ?? "Camera capture failed."
        DispatchQueue.main.async { [weak self] in
            self?.previewCheck?.cancel()
            self?.onError?(message + " Tap Retry camera to reconnect.")
        }
    }
    @objc private func started() {
        DispatchQueue.main.async { [weak self] in self?.checkPreview() }
    }
    private func checkPreview() {
        previewCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.visible, self.active, !self.delivered,
                  let preview = self.view as? CameraPreviewView else { return }
            if !preview.preview.isPreviewing {
                self.onError?("The camera has not delivered a preview. Close any Picture-in-Picture video and tap Retry camera.")
            }
        }
        previewCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: check)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        setActive(active)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        stop()
    }
    func setActive(_ active: Bool) {
        self.active = active
        guard active, visible, !delivered else { stop(); return }
        queue.async { [self] in
            do {
                if !configured {
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                        throw WalletFailure(message: "No rear camera is available on this device.")
                    }
                    let input = try AVCaptureDeviceInput(device: camera)
                    let output = AVCaptureMetadataOutput()
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    // iOS can interrupt capture while a Picture-in-Picture video is playing.
                    // Only opt in on devices where the system explicitly supports it.
                    if session.isMultitaskingCameraAccessSupported {
                        session.isMultitaskingCameraAccessEnabled = true
                    }
                    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                    guard session.canAddInput(input) else { throw WalletFailure(message: "Unable to open the camera.") }
                    session.addInput(input)
                    guard session.canAddOutput(output) else {
                        session.removeInput(input)
                        throw WalletFailure(message: "Camera scanning is unavailable.")
                    }
                    session.addOutput(output)
                    guard output.availableMetadataObjectTypes.contains(.qr) else {
                        session.removeOutput(output); session.removeInput(input)
                        throw WalletFailure(message: "QR scanning is unavailable on this camera.")
                    }
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    output.metadataObjectTypes = [.qr]
                    configured = true
                }
                if !session.isRunning { session.startRunning() }
                if !session.isRunning {
                    throw WalletFailure(message: "The camera could not start. Close other camera apps, then reopen the scanner.")
                }
            } catch { DispatchQueue.main.async { self.onError?(error.localizedDescription) } }
        }
    }
    func stop() { previewCheck?.cancel(); queue.async { [self] in if session.isRunning { session.stopRunning() } } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        delivered = true; stop(); onScan?(value)
    }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
