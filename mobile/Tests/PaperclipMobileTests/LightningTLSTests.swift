import XCTest
import Security
import CryptoKit
@testable import PaperclipMobile

private final class TrustSpace: URLProtectionSpace {
    let suppliedTrust: SecTrust?
    init(_ trust: SecTrust?) {
        suppliedTrust = trust
        super.init(host: "paperclip-test.invalid", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var serverTrust: SecTrust? { suppliedTrust }
}
private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
final class LightningTLSTests: XCTestCase {
    private func check(pin: String, trust: SecTrust?, expected: URLSession.AuthChallengeDisposition, failure: LightningTLSFailure?) {
        let delegate = NodeSessionDelegate(pin: pin, diagnostics: nil)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://paperclip-test.invalid")!)
        let challenge = URLAuthenticationChallenge(protectionSpace: TrustSpace(trust), proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
        var called = false
        delegate.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
            called = true
            XCTAssertEqual(disposition, expected)
            XCTAssertEqual(credential != nil, expected == .useCredential)
        }
        XCTAssertTrue(called)
        XCTAssertEqual(delegate.failure, failure)
    }
    func testPinnedCertificateRejectsMismatchWithoutTrustBypass() throws {
        let data = try Data(contentsOf: Bundle.module.url(forResource: "tls-test", withExtension: "cer", subdirectory: "Fixtures")!)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "paperclip-test.invalid" as CFString), &trust), errSecSuccess)
        let pin = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        check(pin: pin.uppercased(), trust: trust, expected: .useCredential, failure: nil)
        check(pin: String(repeating: "0", count: 64) + ", " + pin.uppercased(), trust: trust, expected: .useCredential, failure: nil)
        check(pin: String(repeating: "0", count: 64) + "," + String(repeating: "1", count: 64), trust: trust, expected: .cancelAuthenticationChallenge, failure: .pinMismatch)
        check(pin: String(repeating: "0", count: 64), trust: trust, expected: .cancelAuthenticationChallenge, failure: .pinMismatch)
        check(pin: pin, trust: nil, expected: .cancelAuthenticationChallenge, failure: .missingTrust)
        check(pin: "", trust: trust, expected: .performDefaultHandling, failure: nil)
    }
}
