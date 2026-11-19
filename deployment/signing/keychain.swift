import Foundation
import Security
import CryptoKit
SecKeychainSetUserInteractionAllowed(false)
let args = CommandLine.arguments
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
guard args.count == 3 else { fail("Use action and account") }
let action = args[1], account = args[2]
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "xyz.paperclip.release-signing", kSecAttrAccount as String: account, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
if action == "store" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty && data.count <= 256 else { fail("Invalid credential length") }
    var add = query; add[kSecValueData as String] = data; add[kSecAttrLabel as String] = "Paperclip release signing · " + account
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Keychain store failed without prompting: \(status)") }
} else {
    var get = query; get[kSecReturnData as String] = true; get[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(get as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { fail("Keychain read failed without prompting: \(status)") }
    if action == "read" { FileHandle.standardOutput.write(data) }
    else if action == "seal" || action == "open" {
        guard let keyData = Data(base64Encoded: data), keyData.count == 32 else { fail("Invalid archive key") }
        let input = FileHandle.standardInput.readDataToEndOfFile(), aad = Data("PAPERCLIP-SIGNING-BACKUP-1\n".utf8)
        do {
            let key = SymmetricKey(data: keyData)
            if action == "seal" {
                let box = try AES.GCM.seal(input, using: key, authenticating: aad)
                guard let combined = box.combined else { fail("Encryption failed") }
                FileHandle.standardOutput.write(aad + combined)
            } else {
                guard input.starts(with: aad) else { fail("Invalid archive") }
                let box = try AES.GCM.SealedBox(combined: input.dropFirst(aad.count))
                FileHandle.standardOutput.write(try AES.GCM.open(box, using: key, authenticating: aad))
            }
        } catch { fail("Signing backup authentication failed") }
    } else { fail("Unknown action") }
}
