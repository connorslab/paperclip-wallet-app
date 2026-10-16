import AVFoundation
import CoreMotion
import CryptoKit
import SwiftUI
import PaperclipMobile

/// Sensor buffers are hashed on one serial queue, never recorded to disk or sent over the network.
final class SensorEntropyCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "xyz.paperclip.seed-sensors")
    private let session = AVCaptureSession()
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var hasher = SHA256()
    private var counts = [0, 0, 0]
    private var health = [SensorSampleHealth(), SensorSampleHealth(), SensorSampleHealth()]
    private var active = false
    private var lastReport = Date.distantPast
    private var lastFrame = Date.distantPast
    private var report: (([Int], [SensorSampleHealth], String) -> Void)?

    func start(camera: Bool, microphone: Bool, gyro: Bool, report: @escaping ([Int], [SensorSampleHealth], String) -> Void) {
        queue.async {
            self.report = report
            self.hasher = SHA256(); self.counts = [0, 0, 0]; self.health = [SensorSampleHealth(), SensorSampleHealth(), SensorSampleHealth()]; self.active = true
            self.hasher.update(data: Data("Paperclip/sensor-stream/v1".utf8))
            self.session.beginConfiguration()
            self.session.sessionPreset = .low
            var unavailable: [String] = []
            if camera {
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                    self.session.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    if self.session.canAddOutput(output) {
                        self.session.addOutput(output); output.setSampleBufferDelegate(self, queue: self.queue)
                    } else { unavailable.append("Camera") }
                } else { unavailable.append("Camera") }
            }
            if microphone {
                if let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                    self.session.addInput(input)
                    let output = AVCaptureAudioDataOutput()
                    if self.session.canAddOutput(output) {
                        self.session.addOutput(output); output.setSampleBufferDelegate(self, queue: self.queue)
                    } else { unavailable.append("Microphone") }
                } else { unavailable.append("Microphone") }
            }
            self.session.commitConfiguration()
            if !self.session.inputs.isEmpty { self.session.startRunning() }
            if gyro {
                if self.motion.isGyroAvailable {
                    self.motion.gyroUpdateInterval = 0.05
                    self.motionQueue.underlyingQueue = self.queue
                    self.motion.startGyroUpdates(to: self.motionQueue) { [weak owner = self] value, _ in
                        guard let self = owner, self.active, let value else { return }
                        var bytes = Data()
                        for number in [value.timestamp, value.rotationRate.x, value.rotationRate.y, value.rotationRate.z] {
                            var bits = number.bitPattern.bigEndian
                            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
                        }
                        self.add(bytes, source: 2)
                    }
                } else { unavailable.append("Gyroscope") }
            }
            report(self.counts, self.health, unavailable.isEmpty ? "Move your phone and vary the scene and sounds around you." : "Unavailable: \(unavailable.joined(separator: ", ")). Other permitted sources can still contribute.")
        }
    }
    private func add(_ bytes: Data, source: Int) {
        guard active, !bytes.isEmpty else { return }
        hasher.update(data: Data([UInt8(source)]))
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: bytes); counts[source] += 1
        // Exclude the gyroscope timestamp from diagnostics: changing clock bits
        // must not disguise a stuck motion source.
        health[source].observe(source == 2 ? Data(bytes.dropFirst(8)) : bytes)
        if Date().timeIntervalSince(lastReport) >= 0.5 {
            lastReport = Date(); report?(counts, health, "")
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active else { return }
        if output is AVCaptureVideoDataOutput {
            guard Date().timeIntervalSince(lastFrame) >= 0.2, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            lastFrame = Date()
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            if let address = CVPixelBufferGetBaseAddress(pixel) {
                add(Data(bytes: address, count: CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel)), source: 0)
            }
        } else if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length <= 1_048_576 else { return }
            var bytes = Data(count: length)
            let result = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            if result == kCMBlockBufferNoErr { add(bytes, source: 1) }
        }
    }
    func stop(completion: ((Data?) -> Void)? = nil) {
        queue.async {
            self.active = false
            self.motion.stopGyroUpdates()
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration()
            self.report?(self.counts, self.health, "")
            let digest = self.health.contains(where: { $0.packets >= 3 && $0.bytes >= 256 && !$0.looksStuck }) ? Data(self.hasher.finalize()) : nil
            self.hasher = SHA256(); self.counts = [0, 0, 0]; self.health = [SensorSampleHealth(), SensorSampleHealth(), SensorSampleHealth()]; self.report = nil
            completion?(digest)
        }
    }
}

@MainActor
final class SensorEntropyCollector: ObservableObject {
    @Published var collecting = false
    @Published var finishing = false
    @Published var counts = [0, 0, 0]
    @Published var health = [SensorSampleHealth(), SensorSampleHealth(), SensorSampleHealth()]
    @Published var message = ""
    @Published var digest: Data?
    private let capture = SensorEntropyCapture()
    private var generation = UUID()
    private var timeout: Task<Void, Never>?
    func start(camera: Bool, microphone: Bool, gyro: Bool) async {
        clear()
        let token = generation
        collecting = true
        let videoAllowed = camera ? await AVCaptureDevice.requestAccess(for: .video) : false
        guard generation == token else { return }
        let audioAllowed = microphone ? await AVCaptureDevice.requestAccess(for: .audio) : false
        guard generation == token else { return }
        let permissionNote = (camera && !videoAllowed) || (microphone && !audioAllowed) ? "Some permissions were denied. Enable them in iOS Settings, or use another source. " : ""
        message = permissionNote + "Collecting samples…"
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == token else { return }
            self.finish()
        }
        capture.start(camera: videoAllowed, microphone: audioAllowed, gyro: gyro) { [weak self] counts, health, note in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.counts = counts; self.health = health
                if !note.isEmpty { self.message = permissionNote + note }
            }
        }
    }
    func finish() {
        guard collecting, !finishing else { return }
        finishing = true
        timeout?.cancel(); timeout = nil
        let token = generation
        capture.stop { [weak self] digest in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.collecting = false; self.finishing = false; self.digest = digest
                self.message = digest == nil ? "Too few or repetitive samples. Collect again with another source, or choose secure system randomness." : "Samples collected. Sensors are now off."
            }
        }
    }
    func clear() {
        generation = UUID(); timeout?.cancel(); timeout = nil; capture.stop()
        collecting = false; finishing = false; digest = nil; counts = [0, 0, 0]; health = [SensorSampleHealth(), SensorSampleHealth(), SensorSampleHealth()]; message = ""
    }
}
