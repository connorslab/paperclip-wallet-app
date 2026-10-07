import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    let onScan: (String) -> Void
    @State private var allowed = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            ZStack {
                PaperclipTheme.navy.ignoresSafeArea()
                if allowed {
                    CameraScanner(active: scene == .active) { value in onScan(value); dismiss() } onError: { error = $0 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .bottom)
                }
                VStack {
                    Text("Scan a payment QR code. Review the recipient and amount before sending.")
                        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
                    Spacer()
                    if !error.isEmpty {
                        Text(error).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
                        if let url = URL(string: UIApplication.openSettingsURLString) {
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
    override func loadView() {
        view = CameraPreviewView()
        let preview = (view as! CameraPreviewView).preview
        preview.session = session
        preview.videoGravity = .resizeAspectFill
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
    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        delivered = true; stop(); onScan?(value)
    }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
