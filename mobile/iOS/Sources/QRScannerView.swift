import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void
    @State private var allowed = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            ZStack {
                PaperclipTheme.navy.ignoresSafeArea()
                if allowed {
                    CameraScanner { value in onScan(value); dismiss() } onError: { error = $0 }
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
                .task {
                    switch AVCaptureDevice.authorizationStatus(for: .video) {
                    case .authorized: allowed = true
                    case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
                    default: allowed = false
                    }
                    if !allowed { error = "Allow camera access in Settings to scan a QR code. You can also paste a payment request." }
                }
        }
    }
}

private struct CameraScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan; controller.onError = onError
        return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "paperclip.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    override func viewDidLoad() {
        super.viewDidLoad()
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview); self.preview = preview
        queue.async { [self] in
            do {
                guard let camera = AVCaptureDevice.default(for: .video) else { throw WalletFailure(message: "No camera is available on this device.") }
                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureMetadataOutput()
                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw WalletFailure(message: "Camera scanning is unavailable.")
                }
                session.addInput(input); session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                session.commitConfiguration()
                session.startRunning()
            } catch { DispatchQueue.main.async { self.onError?(error.localizedDescription) } }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { queue.async { [self] in session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        delivered = true; stop(); onScan?(value)
    }
}
