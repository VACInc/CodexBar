import AppKit
import CodexBarCore
import Observation

extension StatusItemController {
    func observeCloudSyncChanges() {
        withObservationTracking {
            _ = self.cloudSyncState.fleetDevices
            _ = self.cloudSyncState.fleetSnapshots
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeCloudSyncChanges()
                self.invalidateMenus(refreshOpenMenus: true)
            }
        }
    }

    func fleetAccountProjection(for provider: UsageProvider) -> FleetAccountMenuProjection {
        let iCloudSnapshots: [AccountSnapshotSyncPayload] = if self.settings.iCloudSyncEnabled,
                                                               self.settings.iCloudSyncSnapshotsEnabled,
                                                               self.settings.iCloudSyncShowFleetAccounts
        {
            Array(self.cloudSyncState.fleetSnapshots.values)
        } else {
            []
        }
        let remoteSnapshots = self.store.remoteCodexBarSnapshots
        guard !iCloudSnapshots.isEmpty || !remoteSnapshots.isEmpty else {
            return FleetAccountMenuProjection(fallback: nil, additionalAccounts: [])
        }
        let localSnapshots = self.store.cloudSyncAccountSnapshots()
        return FleetAccountMenuPlanner.projection(
            provider: provider,
            snapshots: iCloudSnapshots + remoteSnapshots,
            currentDeviceID: self.settings.iCloudSyncDeviceID,
            localAccountKeys: self.store.cloudSyncLocalAccountKeys(for: provider),
            hasLocalUsage: localSnapshots.contains(where: { $0.provider == provider.instanceID }))
    }

    func addFleetAccountMenuCards(
        _ snapshots: [AccountSnapshotSyncPayload],
        to menu: NSMenu,
        context: MenuCardContext)
    {
        guard !snapshots.isEmpty else { return }
        if menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
        for (index, snapshot) in snapshots.enumerated() {
            guard let model = self.fleetAccountMenuCardModel(snapshot) else { continue }
            menu.addItem(self.makeMenuCardItem(
                FleetAccountMenuCardView(model: model, width: context.menuWidth),
                id: "fleetAccount-\(snapshot.accountKey)",
                width: context.menuWidth,
                heightCacheScope: "fleet-\(context.currentProvider.rawValue)-\(snapshot.accountKey)",
                heightCacheFingerprint: model.heightFingerprint(section: "fleetAccount"),
                containsInteractiveControls: false))
            if index < snapshots.count - 1 {
                menu.addItem(.separator())
            }
        }
        if menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
    }

    func addFleetFallback(
        _ projection: FleetAccountMenuProjection,
        to menu: NSMenu,
        context: MenuCardContext) -> Bool
    {
        guard let fallback = projection.fallback else { return false }
        self.addFleetAccountMenuCards(
            [fallback] + projection.additionalAccounts,
            to: menu,
            context: context)
        return true
    }

    func fleetAccountMenuCardModel(
        _ snapshot: AccountSnapshotSyncPayload) -> UsageMenuCardView.Model?
    {
        guard let provider = snapshot.provider.firstPartyProvider else { return nil }
        let deviceName = if snapshot.deviceID == "remote-codexbar" {
            L("remote CodexBar")
        } else {
            self.cloudSyncState.fleetDevices.values
                .first(where: { $0.deviceID == snapshot.deviceID })?
                .hostName ?? L("another Mac")
        }
        let badge = FleetAccountMenuPlanner.badge(deviceName: deviceName, fetchedAt: snapshot.fetchedAt)
        let label = snapshot.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySnapshot = self.fleetAccountDisplaySnapshot(
            snapshot.usage,
            provider: provider,
            label: label)
        return self.menuCardModel(
            for: provider,
            snapshotOverride: displaySnapshot,
            forceOverrideCard: true,
            accountOverride: AccountInfo(email: label.isEmpty ? nil : label, plan: nil),
            subtitleOverride: badge)
    }

    private func fleetAccountDisplaySnapshot(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider,
        label: String) -> UsageSnapshot
    {
        guard !label.isEmpty,
              snapshot.accountEmail(for: provider)?.caseInsensitiveCompare(label) != .orderedSame
        else { return snapshot }
        let identity = snapshot.identity
        return snapshot.withIdentity(ProviderIdentitySnapshot(
            providerID: identity?.providerID ?? provider.instanceID,
            accountEmail: label,
            accountOrganization: identity?.accountOrganization,
            loginMethod: identity?.loginMethod,
            accountID: identity?.accountID))
    }
}
