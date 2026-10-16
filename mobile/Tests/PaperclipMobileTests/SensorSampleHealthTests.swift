import XCTest
@testable import PaperclipMobile

final class SensorSampleHealthTests: XCTestCase {
    func testStuckAndRepeatedInput() {
        var health = SensorSampleHealth()
        XCTAssertEqual(health.empiricalMinEntropy, 0)
        health.observe(Data(repeating: 0, count: 512))
        XCTAssertTrue(health.looksStuck)
        XCTAssertEqual(health.longestByteRun, 512)
        XCTAssertEqual(health.empiricalMinEntropy, 0)
        var repeated = SensorSampleHealth()
        let bytes = Data((0...255).map(UInt8.init))
        for _ in 0..<3 { repeated.observe(bytes) }
        XCTAssertEqual(repeated.repeatedPackets, 2)
        XCTAssertTrue(repeated.looksStuck)
        // A perfectly predictable counter scores 8 marginal bits/byte: this
        // statistic MUST NOT be used as a security estimate or entropy budget.
        XCTAssertEqual(repeated.empiricalMinEntropy, 8, accuracy: 0.000001)
    }
    func testSamplingIsBoundedAndIncludesPixelChannels() {
        var health = SensorSampleHealth()
        let pixels = Data(Array(repeating: [UInt8(1), 2, 3, 255], count: 10000).flatMap { $0 })
        health.observe(pixels)
        XCTAssertEqual(health.bytes, 4096)
        XCTAssertEqual(health.distinctValues, 4)
        XCTAssertEqual(health.mostCommonFraction, 0.25, accuracy: 0.000001)
        XCTAssertEqual(health.empiricalMinEntropy, 2, accuracy: 0.000001)
    }
}
