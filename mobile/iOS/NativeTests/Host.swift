import SwiftUI

/// Supplies an isolated container and Keychain entitlement for native adapter tests.
/// It never creates a wallet, starts Tor, or contacts a service on launch.
@main struct NativeTestHost: App {
    var body: some Scene { WindowGroup { Color.clear } }
}
