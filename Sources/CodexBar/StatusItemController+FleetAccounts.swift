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
        if self.settings.usesRemoteCodexBarProvidersOnly {
            return FleetAccountMenuPlanner.projection(
                provider: provider,
                snapshots: self.store.remoteCodexBarSnapshots,
                currentDeviceID: self.settings.iCloudSyncDeviceID,
                localAccountKeys: [],
                hasLocalUsage: false,
                activeAccountKey: self.store.remoteCodexBarActiveAccountKeys[provider.instanceID])
        }
        let iCloudSnapshots: [AccountSnapshotSyncPayload] = if self.settings.iCloudSyncEnabled,
                                                               self.settings.iCloudSyncSnapshotsEnabled,
                                                               self.settings.iCloudSyncShowFleetAccounts
        {
            Array(self.cloudSyncState.fleetSnapshots.values)
        } else {
            []
        }
        let remoteSnapshots: [AccountSnapshotSyncPayload] = if let activeConfigurationID = self.settings
            .remoteCodexBarConfiguration?.configurationID,
            self.store.remoteCodexBarSnapshotConfigurationID == activeConfigurationID
        {
            self.store.remoteCodexBarSnapshots
        } else {
            []
        }
        guard !iCloudSnapshots.isEmpty || !remoteSnapshots.isEmpty else {
            return FleetAccountMenuProjection(fallback: nil, additionalAccounts: [])
        }
        let localSnapshots = self.store.cloudSyncAccountSnapshots()
        return FleetAccountMenuPlanner.projection(
            provider: provider,
            snapshots: iCloudSnapshots + remoteSnapshots,
            currentDeviceID: self.settings.iCloudSyncDeviceID,
            localAccountKeys: self.store.cloudSyncLocalAccountKeys(for: provider),
            hasLocalUsage: localSnapshots.contains(where: { $0.provider == provider.instanceID }),
            activeAccountKey: remoteSnapshots.isEmpty
                ? nil
                : self.store.remoteCodexBarActiveAccountKeys[provider.instanceID])
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
        captureMenu: NSMenu? = nil,
        context: MenuCardContext) -> Bool
    {
        guard let fallback = projection.fallback else { return false }
        let accounts = [fallback] + projection.additionalAccounts
        if self.addCompactFleetAccountMenu(accounts, to: menu, captureMenu: captureMenu ?? menu, context: context) {
            return true
        }
        self.addFleetAccountMenuCards(accounts, to: menu, context: context)
        return true
    }

    /// Renders remote accounts through the shared multi-account layout so a
    /// remote provider presents the way the same provider would locally.
    ///
    /// Stacked layout keeps the classic one-card-per-account list until the
    /// compact threshold, matching local stacked lists. Segmented layout has no
    /// remote switcher to drive (activation belongs to the serving Mac), so it
    /// uses the compact plan from two accounts up: the active account keeps its
    /// card and the rest are one-line rows that expand on click.
    ///
    /// Returns false when the caller should fall back to stacked fleet cards.
    func addCompactFleetAccountMenu(
        _ snapshots: [AccountSnapshotSyncPayload],
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext) -> Bool
    {
        guard snapshots.count > 1 else { return false }
        let provider = context.currentProvider
        let projected = self.projectedFleetAccounts(snapshots, provider: provider)
        let minimumCompactAccountCount = self.settings.multiAccountMenuLayout == .stacked
            ? AccountMenuLayoutPlanner.compactLayoutMinimumAccountCount
            : 2
        let plan = self.compactAccountPlan(
            for: provider,
            accounts: projected,
            minimumCompactAccountCount: minimumCompactAccountCount)
        guard plan.usesCompactLayout else { return false }
        let snapshotsByKey = Dictionary(
            snapshots.map { ($0.accountKey, $0) },
            uniquingKeysWith: { first, _ in first })
        if menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
        self.addCompactAccountMenuRows(
            CompactAccountMenuRendering(
                plan: plan,
                accounts: projected,
                idPrefix: "fleetAccount",
                cardModel: { [weak self] projectedAccount in
                    guard let self,
                          let snapshot = snapshotsByKey[projectedAccount.id.opaqueID] else { return nil }
                    return self.fleetAccountMenuCardModel(snapshot)
                },
                planAction: nil,
                cardOpacity: 0.78),
            to: menu,
            captureMenu: captureMenu,
            context: context)
        return true
    }

    /// Projects fleet snapshots into the provider-neutral account model the
    /// shared layout planner consumes. Remote accounts can never be activated
    /// from here: the serving device owns account selection.
    func projectedFleetAccounts(
        _ snapshots: [AccountSnapshotSyncPayload],
        provider: UsageProvider) -> [ProviderAccountUsageSnapshot]
    {
        let activeAccountKey = self.store.remoteCodexBarActiveAccountKeys[provider.instanceID]
        return snapshots.enumerated().map { index, snapshot in
            let label = snapshot.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let isActive = activeAccountKey.map { $0 == snapshot.accountKey } ?? (index == 0)
            return ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: "fleet-account", opaqueID: snapshot.accountKey),
                provider: provider,
                displayLabel: label.isEmpty ? String(format: L("Account %d"), index + 1) : label,
                isActive: isActive,
                canActivate: false,
                snapshot: snapshot.usage,
                error: nil,
                sourceLabel: nil)
        }
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
