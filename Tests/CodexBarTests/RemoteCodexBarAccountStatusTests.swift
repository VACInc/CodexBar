import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Remote accounts and remote-only cards must describe what the server reported:
/// served per-account errors, the remote fetch time, and the remote snapshot/error
/// instead of local-probe state that remote-only mode never refreshes.
struct RemoteCodexBarAccountStatusTests {
    @Test
    func `projection keeps per account errors keyed by account`() throws {
        let projection = try Self.projection()
        let codex = projection.snapshots.filter { $0.provider == UsageProvider.codex.instanceID }
        #expect(codex.count == 3)
        let errored = codex.filter { $0.displayLabel != "Main" }
        #expect(errored.count == 2)
        for payload in errored {
            #expect(projection.accountErrors[payload.accountKey] == "Saved usage refresh failed")
        }
        let main = try #require(codex.first { $0.displayLabel == "Main" })
        #expect(projection.accountErrors[main.accountKey] == nil)
    }

    @MainActor
    @Test
    func `errored remote accounts render their served error instead of a blank row`() throws {
        let settings = testSettingsStore(suiteName: "RemoteCodexBarAccountStatusTests-errors")
        settings.remoteCodexBarServerURL = "https://example.com"
        settings.remoteCodexBarBearerToken = "token"
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let projection = try Self.projection()
        store.remoteCodexBarSnapshots = projection.snapshots
        store.remoteCodexBarActiveAccountKeys = projection.activeAccountKeys
        store.remoteCodexBarAccountErrors = projection.accountErrors
        store.remoteCodexBarSnapshotConfigurationID = settings.remoteCodexBarConfiguration?.configurationID

        try withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
            let snapshots = store.remoteCodexBarSnapshots
            let accounts = controller.projectedFleetAccounts(snapshots, provider: .codex)
            let errored = accounts.filter { $0.displayLabel != "Main" }
            #expect(errored.count == 2)
            #expect(errored.allSatisfy { $0.error == "Saved usage refresh failed" })
            #expect(accounts.first { $0.displayLabel == "Main" }?.error == nil)

            let plan = AccountMenuLayoutPlanner.plan(accounts: accounts, minimumCompactAccountCount: 2)
            let compactRows = plan.rows.compactMap { row -> AccountMenuLayoutPlanner.CompactRow? in
                if case let .compact(compact) = row { return compact }
                return nil
            }
            #expect(compactRows.count == 2)
            for row in compactRows {
                let model = MenuCardCompactAccountRowView.Model(row: row, resetTimeDisplayStyle: .countdown)
                #expect(model.hasError)
                #expect(model.detailLines == ["Saved usage refresh failed"])
            }

            let erroredPayload = try #require(snapshots.first { $0.displayLabel == "Saved A" })
            let card = try #require(controller.fleetAccountMenuCardModel(erroredPayload))
            #expect(card.subtitleStyle == .error)
            #expect(card.subtitleText == "Saved usage refresh failed")

            let healthyPayload = try #require(snapshots.first { $0.displayLabel == "Main" })
            let healthyCard = try #require(controller.fleetAccountMenuCardModel(healthyPayload))
            #expect(healthyCard.subtitleText.contains("remote CodexBar"))
        }
    }

    @MainActor
    @Test
    func `successful remote fetch is timestamped and a permanent failure clears it`() async {
        let settings = testSettingsStore(suiteName: "RemoteCodexBarAccountStatusTests-fetched-at")
        settings.remoteCodexBarServerURL = "https://example.com"
        settings.remoteCodexBarBearerToken = "token"
        let status = StatusBox()
        let transport = ProviderHTTPTransportHandler { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: status.code, httpVersion: nil, headerFields: nil))
            return (Data(Self.json.utf8), response)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            remoteCodexBarClient: RemoteCodexBarSnapshotClient(transport: transport))
        #expect(store.remoteCodexBarLastSuccessfulFetchAt == nil)

        let before = Date()
        await store.refreshRemoteCodexBarSnapshot()
        let fetchedAt = store.remoteCodexBarLastSuccessfulFetchAt
        #expect(fetchedAt.map { $0 >= before } == true)
        #expect(store.remoteCodexBarAccountErrors.count == 2)

        // A transient failure keeps the last good fetch time alongside the retained cards.
        status.code = 503
        await store.refreshRemoteCodexBarSnapshot()
        #expect(store.remoteCodexBarLastSuccessfulFetchAt == fetchedAt)
        #expect(store.remoteCodexBarError != nil)

        status.code = 401
        await store.refreshRemoteCodexBarSnapshot()
        #expect(store.remoteCodexBarLastSuccessfulFetchAt == nil)
        #expect(store.remoteCodexBarAccountErrors.isEmpty)
    }

    @MainActor
    @Test
    func `remote only codex card uses the served snapshot and error instead of local probe state`() {
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarAccountStatusTests-remote-only-card",
            remoteCodexBarTokenStore: InMemoryRemoteCodexBarTokenStore(value: RemoteCodexBarStoredCredential(
                serverURL: "https://example.com",
                bearerToken: "token",
                allowsPlainHTTP: false)))
        settings.remoteCodexBarRemoteOnlyEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let localError = "No available fetch strategy for codex"
        store.errors[.codex] = localError
        store.remoteCodexBarProviderIDs = [.codex]
        store.remoteCodexBarPrimarySnapshots[.codex] = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 4, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "remote@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))

        let healthy = store.menuCardModel(for: .codex)
        #expect(!healthy.subtitleText.contains(localError))
        #expect(healthy.subtitleStyle != .error)
        #expect(healthy.metrics.contains { $0.percent == 96 })

        store.remoteCodexBarError = "Remote CodexBar is unreachable."
        let unreachable = store.menuCardModel(for: .codex)
        #expect(unreachable.subtitleText == "Remote CodexBar is unreachable.")
        #expect(unreachable.subtitleStyle == .error)
    }

    private static func projection() throws -> RemoteCodexBarProjection {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(RemoteCodexBarSnapshot.self, from: Data(Self.json.utf8))
        let serverURL = try #require(URL(string: "http://mini.example:8484/dashboard/v1/snapshot"))
        return RemoteCodexBarProjection.make(snapshot: snapshot, serverURL: serverURL)
    }

    private final class StatusBox: @unchecked Sendable {
        var code = 200
    }

    private static let json = """
    {
      "schemaVersion": 1,
      "generatedAt": "2026-10-07T12:00:00Z",
      "staleAfterSeconds": 180,
      "providers": [
        {
          "id": "codex",
          "name": "Codex",
          "enabled": true,
          "source": "oauth",
          "status": null,
          "identity": {"accountEmail": "dev@example.com", "plan": "Pro"},
          "windows": [
            {"kind": "weekly", "label": "Weekly", "usedPercent": 4, "remainingPercent": 96, "resetAt": null}
          ],
          "credits": null,
          "cost": null,
          "error": null,
          "updatedAt": "2026-10-07T11:50:00Z",
          "accounts": [
            {
              "id": "saved:1",
              "label": "Saved A",
              "active": false,
              "identity": {"accountEmail": "saved-a@example.com", "plan": null},
              "windows": [],
              "pace": null,
              "error": "Saved usage refresh failed",
              "updatedAt": "2026-10-07T11:59:00Z"
            },
            {
              "id": "saved:2",
              "label": "Main",
              "active": false,
              "identity": {"accountEmail": "dev@example.com", "plan": "Pro"},
              "windows": [
                {"kind": "weekly", "label": "Weekly", "usedPercent": 4, "remainingPercent": 96, "resetAt": null}
              ],
              "pace": null,
              "error": null,
              "updatedAt": "2026-10-07T11:50:00Z"
            },
            {
              "id": "saved:3",
              "label": "Saved B",
              "active": false,
              "identity": {"accountEmail": "saved-b@example.com", "plan": null},
              "windows": [],
              "pace": null,
              "error": "Saved usage refresh failed",
              "updatedAt": "2026-10-07T11:58:00Z"
            }
          ]
        }
      ]
    }
    """
}
