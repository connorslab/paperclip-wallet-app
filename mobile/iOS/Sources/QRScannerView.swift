import SwiftUI
import AVFoundation
import VisionKit

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    let title: String
    let instruction: String
    let process: (String) -> (Bool, String)
    init(onScan: @escaping (String) -> Void) {
        title = "Scan payment"; instruction = "Scan a payment QR code. Review the recipient and amount before sending."
        process = { value in onScan(value); return (true, "") }
    }
    init(title: String, instruction: String, onFrame: @escaping (String) -> (Bool, String)) {
        self.title = title; self.instruction = instruction; process = onFrame
    }
    @State private var progress = ""
    @State private var allowed = false
    @State private var error = ""
    @State private var scannerID = UUID()
    var body: some View {
        NavigationStack {
            ZStack {
                PaperclipTheme.navy.ignoresSafeArea()
                if allowed && DataScannerViewController.isSupported {
                    CameraScanner(active: scene == .active) { value in
                        let result = process(value); progress = result.1
                        if result.0 { dismiss() }; return result.0
                    } onError: { error = $0 }
                        .id(scannerID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .bottom)
                }
                VStack {
                    Text(instruction)
                        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
                    Spacer()
                    if !progress.isEmpty { Text(progress).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)).padding() }
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
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { dismiss() } }
                .task(id: scene) {
                    guard scene == .active else { return }
                    switch AVCaptureDevice.authorizationStatus(for: .video) {
                    case .authorized: allowed = true
                    case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
                    default: allowed = false
                    }
                    if allowed { error = DataScannerViewController.isSupported ? "" : "Live QR scanning is not supported on this device. Paste a payment request instead." }
                    if !allowed { error = "Allow camera access in Settings to scan a QR code. You can also paste a payment request." }
                }
        }
    }
}

private struct CameraScanner: UIViewControllerRepresentable {
    let active: Bool
    let onScan: (String) -> Bool
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan; controller.onError = onError
        return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onScan = onScan; controller.onError = onError
        controller.setActive(active)
    }
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

// Let VisionKit own capture, preview rendering, focus, and QR recognition together.
// No wallet operation is performed here: a scan only fills the payment review form.
private final class ScannerController: UIViewController, DataScannerViewControllerDelegate {
    var onScan: ((String) -> Bool)?
    var onError: ((String) -> Void)?
    private let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isPinchToZoomEnabled: true,
        isGuidanceEnabled: true,
        isHighlightingEnabled: true
    )
    private var visible = false
    private var active = true
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        scanner.delegate = self
        addChild(scanner)
        view.addSubview(scanner.view)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
            scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        scanner.didMove(toParent: self)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        startIfNeeded()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        stop()
    }
    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if active { startIfNeeded() } else { stop() }
    }
    private func startIfNeeded() {
        guard visible, active, !delivered, !scanner.isScanning else { return }
        guard DataScannerViewController.isAvailable else {
            onError?("Camera scanning is unavailable. Check camera permission and any Screen Time restrictions, then retry.")
            return
        }
        do {
            try scanner.startScanning()
            onError?("")
        } catch {
            onError?("Unable to start the camera: \(error.localizedDescription). Tap Retry camera to reconnect.")
        }
    }
    func stop() { scanner.stopScanning() }
    private func receive(_ items: [RecognizedItem]) {
        guard visible, active, !delivered else { return }
        for item in items {
            guard case .barcode(let barcode) = item, let value = barcode.payloadStringValue, !value.isEmpty else { continue }
            if onScan?(value) == true { delivered = true; stop() }
            return
        }
    }
    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        receive(addedItems)
    }
    func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        receive(updatedItems)
    }
    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { receive([item]) }
    func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        stop()
        switch error {
        case .cameraRestricted: onError?("Camera access is restricted. Check camera permission and Screen Time settings, then retry.")
        case .unsupported: onError?("Live QR scanning is not supported on this device. Paste a payment request instead.")
        @unknown default: onError?("Camera scanning was interrupted. Tap Retry camera to reconnect.")
        }
    }
}
