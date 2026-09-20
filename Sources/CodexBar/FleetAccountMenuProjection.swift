import CodexBarCore
import Foundation
import SwiftUI

struct FleetAccountMenuProjection {
    let fallback: AccountSnapshotSyncPayload?
    let additionalAccounts: [AccountSnapshotSyncPayload]
}

enum FleetAccountMenuPlanner {
    /// - Parameter activeAccountKey: Account the source device has selected. It
    ///   leads the list so the remote menu opens on the same account the serving
    ///   Mac shows first.
    static func projection(
        provider: UsageProvider,
        snapshots: some Sequence<AccountSnapshotSyncPayload>,
        currentDeviceID: String,
        localAccountKeys: Set<String>,
        hasLocalUsage: Bool,
        activeAccountKey: String? = nil) -> FleetAccountMenuProjection
    {
        let remote = snapshots
            .filter { $0.provider == provider.instanceID && $0.deviceID != currentDeviceID }
        var freshestByAccount = Dictionary(grouping: remote, by: \.accountKey)
            .compactMap { _, candidates in candidates.max(by: self.isOlder) }
            .sorted(by: self.isNewer)
        if let activeAccountKey,
           let activeIndex = freshestByAccount.firstIndex(where: { $0.accountKey == activeAccountKey })
        {
            let active = freshestByAccount.remove(at: activeIndex)
            freshestByAccount.insert(active, at: 0)
        }
        let fallback = hasLocalUsage ? nil : freshestByAccount.first
        let additionalAccounts = freshestByAccount.filter { candidate in
            !localAccountKeys.contains(candidate.accountKey) && candidate.accountKey != fallback?.accountKey
        }
        return FleetAccountMenuProjection(fallback: fallback, additionalAccounts: additionalAccounts)
    }

    static func badge(deviceName: String, fetchedAt: Date, now: Date = .now) -> String {
        "via \(deviceName) · \(self.staleness(fetchedAt: fetchedAt, now: now))"
    }

    static func staleness(fetchedAt: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(fetchedAt)))
        if seconds < 60 {
            return L("just now")
        }
        if seconds < 3600 {
            return String(format: L("%dm ago"), max(1, seconds / 60))
        }
        if seconds < 86400 {
            return String(format: L("%dh ago"), max(1, seconds / 3600))
        }
        return String(format: L("%dd ago"), max(1, seconds / 86400))
    }

    private static func isOlder(_ lhs: AccountSnapshotSyncPayload, _ rhs: AccountSnapshotSyncPayload) -> Bool {
        if lhs.fetchedAt != rhs.fetchedAt {
            return lhs.fetchedAt < rhs.fetchedAt
        }
        return lhs.deviceID < rhs.deviceID
    }

    private static func isNewer(_ lhs: AccountSnapshotSyncPayload, _ rhs: AccountSnapshotSyncPayload) -> Bool {
        if lhs.fetchedAt != rhs.fetchedAt {
            return lhs.fetchedAt > rhs.fetchedAt
        }
        if lhs.accountKey != rhs.accountKey {
            return lhs.accountKey < rhs.accountKey
        }
        return lhs.deviceID < rhs.deviceID
    }
}

struct FleetAccountMenuCardView: View {
    let model: UsageMenuCardView.Model
    let width: CGFloat

    var body: some View {
        UsageMenuCardView(model: self.model, width: self.width)
            .opacity(0.78)
    }
}
