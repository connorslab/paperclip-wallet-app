import BackgroundTasks
import PaperclipMobile
import UserNotifications
import SwiftUI

// The UI cannot touch keys or submit transactions. A native engine owns these operations.
actor UnconnectedEngine: WalletEngine {
    func synchronize() async throws -> WalletSnapshot { throw CocoaError(.fileNoSuchFile) }
    func refreshEligible() async throws { throw CocoaError(.fileNoSuchFile) }
}

@MainActor final class Maintenance: ObservableObject {
    static let shared = Maintenance(engine: NativeWallet.shared)
    static let refreshID = "xyz.paperclippool.wallet.preview.refresh"
    static let processingID = "xyz.paperclippool.wallet.preview.processing"
    @Published var message = "Native wallet connection is not configured. No funds are available in this preview."
    @Published var busy = false
    @Published var notificationStatus = "Notifications have not been enabled."
    private let coordinator: RefreshCoordinator
    private var snapshot: WalletSnapshot?
    private let center = UNUserNotificationCenter.current()
    init(engine: any WalletEngine = UnconnectedEngine()) { coordinator = RefreshCoordinator(engine: engine) }

    func register() {
        for id in [Self.refreshID, Self.processingID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
                Task { @MainActor in self.handle(task) }
            }
        }
    }
    private func handle(_ backgroundTask: BGTask) {
        schedule()
        let work = Task { @MainActor in
            let success = await update(automatic: UserDefaults.standard.bool(forKey: "automaticRefresh"))
            backgroundTask.setTaskCompleted(success: success && !Task.isCancelled)
        }
        // Exactly one completion path; cancellation propagates to the native operation.
        backgroundTask.expirationHandler = { work.cancel() }
    }
    func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingID)
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        let processing = BGProcessingTaskRequest(identifier: Self.processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        do { try BGTaskScheduler.shared.submit(refresh); try BGTaskScheduler.shared.submit(processing) }
        catch { message = "Background scheduling unavailable. Open the app regularly to check Ark expiry." }
    }
    @discardableResult func update(automatic: Bool) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            guard let fresh = try await coordinator.run(automatic: automatic) else { return false }
            snapshot = fresh
            try await replaceReminders(fresh)
            message = "Checked at block \(fresh.tip). Expiry is block-based; reminders use estimated times."
            return true
        } catch is CancellationError {
            message = "Refresh interrupted. Open the app to reconcile its status."
            return false
        } catch {
            // Retain previously scheduled reminders on network/key-access failures.
            message = "Could not check the wallet. Open it with a working connection and unlock it to refresh."
            return false
        }
    }
    func enableNotifications() async {
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            notificationStatus = allowed ? "Expiry reminders enabled." : "Notifications are disabled. Check expiry in the app."
            if allowed, let snapshot { try await replaceReminders(snapshot) }
        } catch { notificationStatus = "Notification permission unavailable. Check iOS Settings." }
    }
    private func replaceReminders(_ snapshot: WalletSnapshot) async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let planned = RefreshPolicy.reminders(snapshot, now: Date())
        // Replace matching IDs first; a scheduling failure keeps older safety reminders.
        for reminder in planned {
            let content = UNMutableNotificationContent()
            content.title = "Paperclip wallet check"
            content.body = reminder.body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(5, reminder.date.timeIntervalSinceNow), repeats: false)
            try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
        let keep = Set(planned.map(\.id))
        let obsolete = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix("paperclip.expiry.") && !keep.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
    }
}
