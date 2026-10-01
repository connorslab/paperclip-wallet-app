import SwiftUI
import PaperclipMobile

@main struct PaperclipApp: App {
    @Environment(\.scenePhase) private var scene
    @StateObject private var maintenance = Maintenance.shared
    init() {
        UserDefaults.standard.register(defaults: ["automaticRefresh": true])
        Maintenance.shared.register()
    }
    var body: some Scene {
        WindowGroup {
            WalletView().environmentObject(maintenance)
                .preferredColorScheme(.dark)
                .task { await maintenance.update(automatic: UserDefaults.standard.bool(forKey: "automaticRefresh")) }
                .onChange(of: scene) { _, phase in
                    if phase == .active {
                        Task { await maintenance.update(automatic: UserDefaults.standard.bool(forKey: "automaticRefresh")) }
                    } else if phase == .background { maintenance.schedule() }
                }
        }
    }
}

struct WalletView: View {
    @EnvironmentObject var maintenance: Maintenance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("automaticRefresh") private var automatic = true
    @State private var engineStatus = ""
    private let orange = Color(red: 1, green: 0.38, blue: 0.17)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("PAPERCLIP", systemImage: "paperclip").font(.headline).foregroundStyle(orange)
                    Text("Your XBT.\nWithin reach.").font(.largeTitle.bold())
                    card {
                        Label("iPhone proof of concept", systemImage: "iphone")
                            .font(.title3.bold())
                        Text("No wallet is connected. This build cannot receive funds or make payments.")
                            .foregroundStyle(.secondary)
                        Text(engineStatus).font(.caption)
                    }
                    card {
                        Label("Keep Ark funds current", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                        Toggle("Attempt automatic refresh", isOn: $automatic).tint(orange)
                        Text("Checks when you open the app and during background time allowed by iOS. Refresh fees may apply. Background execution is not guaranteed.").font(.subheadline).foregroundStyle(.secondary)
                        Button { Task { await maintenance.update(automatic: true) } } label: {
                            HStack { if maintenance.busy { ProgressView() }; Text("Check and refresh eligible funds") }.frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(orange).disabled(maintenance.busy)
                        Text(maintenance.message).font(.caption).accessibilityIdentifier("maintenance-status")
                    }
                    card {
                        Label("Expiry reminders", systemImage: "bell.badge").font(.headline)
                        Text("Get a reminder to open Paperclip before estimated expiry. Block production can change the timing. Reminders do not display your balance or addresses.").font(.subheadline).foregroundStyle(.secondary)
                        Button("Enable notifications") { Task { await maintenance.enableNotifications() } }.tint(orange)
                        Text(maintenance.notificationStatus).font(.caption)
                    }
                    card {
                        Label("Connections", systemImage: "network").font(.headline)
                        Text("Public XBT endpoint, custom RPC, and embedded Tor are planned. They are not connected in this preview.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("Experimental · Not independently audited").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }.background(Color(red: 0.07, green: 0.11, blue: 0.17))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: maintenance.busy)
                .task { engineStatus = EngineProbe.run() }
        }
    }
    func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(red: 0.11, green: 0.16, blue: 0.23), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08)))
    }
}
