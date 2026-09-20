import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Remote (sync) providers with several accounts must present the way the same
/// provider presents locally: every account visible, the serving Mac's active
/// account first, and the layout the multi-account menu setting selects.
struct RemoteCodexBarMultiAccountMenuTests {
    @Test
    func `projection records the active remote account key`() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(RemoteCodexBarSnapshot.self, from: Data(Self.twoAccountsJSON.utf8))
        let serverURL = try #require(URL(string: "https://server.example/dashboard/v1/snapshot"))

        let projection = RemoteCodexBarProjection.make(snapshot: snapshot, serverURL: serverURL)
        let activeKey = try #require(projection.activeAccountKeys[UsageProvider.codex.instanceID])
        let expected = AccountSnapshotSyncPayload.accountKey(
            for: "https://server.example/dashboard/v1/snapshot|codex|slot:2")

        #expect(projection.snapshots.count == 2)
        #expect(activeKey == expected)
    }

    @MainActor
    @Test
    func `fleet projection leads with the active remote account`() throws {
        let settings = testSettingsStore(suiteName: "RemoteCodexBarMultiAccountMenuTests-order")
        settings.remoteCodexBarServerURL = "https://example.com"
        settings.remoteCodexBarBearerToken = "token"
        let fetcher = UsageFetcher()
        let store = self.storeWithRemoteAccounts(settings: settings, fetcher: fetcher)
        let second = store.remoteCodexBarSnapshots[1]
        store.remoteCodexBarActiveAccountKeys = [UsageProvider.codex.instanceID: second.accountKey]

        try withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
            let projection = controller.fleetAccountProjection(for: .codex)
            let fallback = try #require(projection.fallback)

            #expect(fallback.accountKey == second.accountKey)
            #expect(projection.additionalAccounts.count == 1)
        }
    }

    @MainActor
    @Test
    func `remote accounts project as menu accounts with the active one marked`() throws {
        let settings = testSettingsStore(suiteName: "RemoteCodexBarMultiAccountMenuTests-projected")
        settings.remoteCodexBarServerURL = "https://example.com"
        settings.remoteCodexBarBearerToken = "token"
        let fetcher = UsageFetcher()
        let store = self.storeWithRemoteAccounts(settings: settings, fetcher: fetcher)
        let snapshots = store.remoteCodexBarSnapshots
        store.remoteCodexBarActiveAccountKeys = [UsageProvider.codex.instanceID: snapshots[1].accountKey]

        try withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
            let accounts = controller.projectedFleetAccounts(snapshots, provider: .codex)

            #expect(accounts.count == 2)
            #expect(accounts.map(\.isActive) == [false, true])
            #expect(accounts.map(\.displayLabel) == ["Personal", "Work"])
            #expect(accounts.allSatisfy { !$0.canActivate })
            let plan = controller.compactAccountPlan(
                for: .codex,
                accounts: accounts,
                minimumCompactAccountCount: 2)
            #expect(plan.usesCompactLayout)
            #expect(plan.rows.first == .card(accounts[1].id))
        }
    }

    @MainActor
    @Test
    func `stacked layout keeps full cards below the compact threshold`() throws {
        let settings = testSettingsStore(suiteName: "RemoteCodexBarMultiAccountMenuTests-stacked")
        settings.remoteCodexBarServerURL = "https://example.com"
        settings.remoteCodexBarBearerToken = "token"
        settings.multiAccountMenuLayout = .stacked
        let fetcher = UsageFetcher()
        let store = self.storeWithRemoteAccounts(settings: settings, fetcher: fetcher)
        let snapshots = store.remoteCodexBarSnapshots

        try withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
            let accounts = controller.projectedFleetAccounts(snapshots, provider: .codex)
            let plan = controller.compactAccountPlan(for: .codex, accounts: accounts)

            #expect(!plan.usesCompactLayout)
            #expect(plan.rows.count == 2)
        }
    }

    @MainActor
    private func storeWithRemoteAccounts(settings: SettingsStore, fetcher: UsageFetcher) -> UsageStore {
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store.remoteCodexBarSnapshots = [
            self.payload(identity: "remote|codex|slot:1", label: "Personal", usedPercent: 15),
            self.payload(identity: "remote|codex|slot:2", label: "Work", usedPercent: 55),
        ]
        store.remoteCodexBarSnapshotConfigurationID = settings.remoteCodexBarConfiguration?.configurationID
        return store
    }

    private func payload(
        identity: String,
        label: String,
        usedPercent: Double) -> AccountSnapshotSyncPayload
    {
        AccountSnapshotSyncPayload(
            provider: UsageProvider.codex.instanceID,
            deviceID: "remote-codexbar",
            accountIdentity: identity,
            displayLabel: label,
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: .now,
                identity: ProviderIdentitySnapshot(
                    providerID: UsageProvider.codex.instanceID,
                    accountEmail: "person@example.com",
                    accountOrganization: nil,
                    loginMethod: "Plus")))
    }

    private static let twoAccountsJSON = """
    {
      "schemaVersion": 1,
      "generatedAt": "2026-08-28T20:00:00Z",
      "staleAfterSeconds": 180,
      "providers": [{
        "id": "codex",
        "name": "Codex",
        "enabled": true,
        "windows": [],
        "accounts": [
          {
            "id": "slot:1",
            "label": "Personal",
            "active": false,
            "windows": [{"kind": "session", "label": "Session", "usedPercent": 15,
                         "remainingPercent": 85, "resetAt": null}]
          },
          {
            "id": "slot:2",
            "label": "Work",
            "active": true,
            "windows": [{"kind": "session", "label": "Session", "usedPercent": 35,
                         "remainingPercent": 65, "resetAt": null}]
          }
        ]
      }]
    }
    """
}
