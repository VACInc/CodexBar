import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct RemoteCodexBarSnapshotTests {
    @Test
    func `URL validation accepts secure and private transports`() throws {
        let secure = try #require(RemoteCodexBarConfiguration.resolve(
            serverURL: "https://example.com/codexbar/",
            bearerToken: " token "))
        #expect(secure.snapshotURL.absoluteString == "https://example.com/codexbar/dashboard/v1/snapshot")
        #expect(secure.bearerToken == "token")

        let existingEndpoint = try #require(RemoteCodexBarConfiguration.resolve(
            serverURL: "https://example.com/codexbar/dashboard/v1/snapshot",
            bearerToken: "token"))
        #expect(existingEndpoint.snapshotURL.absoluteString ==
            "https://example.com/codexbar/dashboard/v1/snapshot")

        let privateHTTP = try #require(RemoteCodexBarConfiguration.resolve(
            serverURL: "http://192.168.1.20:9876",
            bearerToken: "token",
            allowsPlainHTTP: true))
        #expect(privateHTTP.snapshotURL.absoluteString == "http://192.168.1.20:9876/dashboard/v1/snapshot")
        #expect(RemoteCodexBarConfiguration.resolve(
            serverURL: "http://192.168.1.20:9876",
            bearerToken: "token") == nil)
        #expect(RemoteCodexBarConfiguration.resolve(
            serverURL: "http://127.0.0.1:9876",
            bearerToken: "token") != nil)

        #expect(RemoteCodexBarConfiguration.resolve(serverURL: "http://example.com", bearerToken: "token") == nil)
        #expect(RemoteCodexBarConfiguration.resolve(
            serverURL: "https://user@example.com", bearerToken: "token") == nil)
        #expect(RemoteCodexBarConfiguration.resolve(
            serverURL: "https://example.com?token=bad", bearerToken: "token") == nil)
        #expect(RemoteCodexBarConfiguration.resolve(serverURL: "https://example.com", bearerToken: "  ") == nil)
    }

    @Test
    func `client sends bearer auth decodes schema v1 and projects provider cards`() async throws {
        let body = Data(Self.snapshotJSON.utf8)
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://example.com/dashboard/v1/snapshot")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (body, response)
        }
        let configuration = try #require(RemoteCodexBarConfiguration.resolve(
            serverURL: "https://example.com",
            bearerToken: "secret-value"))
        let snapshot = try await RemoteCodexBarSnapshotClient(transport: transport)
            .fetch(configuration: configuration)
        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.providers.count == 1)

        let projection = RemoteCodexBarProjection.make(snapshot: snapshot, serverURL: configuration.snapshotURL)
        #expect(projection.snapshots.count == 2)
        let provider = try #require(projection.snapshots.first)
        #expect(provider.provider == UsageProvider.codex.instanceID)
        #expect(provider.accountKey == AccountSnapshotSyncPayload.accountKey(for: "person@example.com"))
        #expect(projection.snapshots[1].accountKey ==
            AccountSnapshotSyncPayload.accountKey(for: "work@example.com"))
        #expect(provider.displayLabel == "person@example.com")
        #expect(provider.usage.primary?.usedPercent == 25)
        #expect(provider.usage.secondary?.usedPercent == 60)
        #expect(provider.usage.extraRateWindows?.first?.title == "Spark")
        #expect(provider.usage.identity?.loginMethod == "Plus")
        #expect(provider.usage.details.first?.rows.contains(where: { $0.label == "Today" }) == true)
    }

    @Test
    func `client rejects auth failures and unsupported schemas`() async throws {
        let configuration = try #require(RemoteCodexBarConfiguration.resolve(
            serverURL: "https://example.com",
            bearerToken: "secret-value"))
        let unauthorized = ProviderHTTPTransportHandler { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }
        await #expect(throws: RemoteCodexBarSnapshotError.unauthorized) {
            try await RemoteCodexBarSnapshotClient(transport: unauthorized).fetch(configuration: configuration)
        }

        let unsupported = ProviderHTTPTransportHandler { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            let body = Self.snapshotJSON.replacingOccurrences(
                of: "\"schemaVersion\": 1",
                with: "\"schemaVersion\": 2")
            return (Data(body.utf8), response)
        }
        await #expect(throws: RemoteCodexBarSnapshotError.unsupportedSchema(2)) {
            try await RemoteCodexBarSnapshotClient(transport: unsupported).fetch(configuration: configuration)
        }
    }

    @MainActor
    @Test
    func `settings persist URL and keep bearer token in secure store`() {
        let tokens = InMemoryRemoteCodexBarTokenStore(value: "saved-token")
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-settings",
            remoteCodexBarTokenStore: tokens)
        #expect(settings.remoteCodexBarBearerToken == "saved-token")

        settings.applyRemoteCodexBarConfiguration(
            serverURL: "https://example.com",
            bearerToken: "new-token")
        #expect(settings.userDefaults.string(forKey: "remoteCodexBarServerURL") == "https://example.com")
        #expect(settings.userDefaults.string(forKey: "remoteCodexBarBearerToken") == nil)
        #expect(tokens.storedValues == ["new-token"])
        #expect(settings.remoteCodexBarConfiguration?.bearerToken == "new-token")
    }

    @MainActor
    @Test
    func `private HTTP requires endpoint-bound consent before connecting`() {
        let settings = testSettingsStore(suiteName: "RemoteCodexBarSnapshotTests-private-http-consent")
        #expect(settings.applyRemoteCodexBarConfiguration(
            serverURL: "https://server-a.example.com",
            bearerToken: "server-a-token"))

        #expect(!settings.applyRemoteCodexBarConfiguration(
            serverURL: "http://192.168.1.20:9876",
            bearerToken: "token"))
        #expect(settings.remoteCodexBarServerURL == "https://server-a.example.com")
        #expect(settings.remoteCodexBarBearerToken == "server-a-token")

        #expect(settings.applyRemoteCodexBarConfiguration(
            serverURL: "http://192.168.1.20:9876",
            bearerToken: "token",
            allowsPlainHTTP: true))
        #expect(settings.remoteCodexBarConfiguration != nil)
        #expect(settings.remoteCodexBarAllowsPlainHTTP)
        #expect(settings.userDefaults.bool(forKey: "remoteCodexBarAllowsPlainHTTP"))

        settings.remoteCodexBarServerURL = "http://192.168.1.21:9876"
        #expect(settings.remoteCodexBarServerURL == "http://192.168.1.20:9876")
        #expect(settings.remoteCodexBarConfiguration != nil)
    }

    @MainActor
    @Test
    func `failed token replacement preserves the prior durable authority pair`() async throws {
        let tokens = FailingRemoteCodexBarTokenStore()
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-failed-token-replacement",
            remoteCodexBarTokenStore: tokens)
        #expect(settings.applyRemoteCodexBarConfiguration(
            serverURL: "https://server-a.example.com",
            bearerToken: "server-a-token"))
        tokens.failWrites = true

        #expect(!settings.applyRemoteCodexBarConfiguration(
            serverURL: "https://server-b.example.com",
            bearerToken: "server-b-token"))
        #expect(settings.remoteCodexBarServerURL == "https://server-a.example.com")
        #expect(settings.remoteCodexBarBearerToken == "server-a-token")
        #expect(settings.userDefaults.string(forKey: "remoteCodexBarServerURL") ==
            "https://server-a.example.com")
        #expect(try tokens.loadToken() == "server-a-token")

        let persisted = try #require(RemoteCodexBarConfiguration.resolve(
            serverURL: settings.userDefaults.string(forKey: "remoteCodexBarServerURL") ?? "",
            bearerToken: tokens.loadToken() ?? ""))
        let requests = LockIsolated<[URLRequest]>([])
        let transport = ProviderHTTPTransportHandler { request in
            requests.setValue(requests.value + [request])
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        await #expect(throws: RemoteCodexBarSnapshotError.unauthorized) {
            try await RemoteCodexBarSnapshotClient(transport: transport).fetch(configuration: persisted)
        }
        #expect(requests.value.map(\.url?.host) == ["server-a.example.com"])
        #expect(requests.value.map { $0.value(forHTTPHeaderField: "Authorization") } ==
            ["Bearer server-a-token"])
    }

    @Test
    func `production transport aborts oversized retryable responses without retrying`() async throws {
        RemoteCodexBarOversizedURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteCodexBarOversizedURLProtocol.self]
        let transport = RemoteCodexBarBoundedHTTPTransport(
            maximumResponseBytes: 32,
            configuration: configuration)
        let remoteConfiguration = try #require(RemoteCodexBarConfiguration.resolve(
            serverURL: "https://example.com",
            bearerToken: "secret-value"))

        await #expect(throws: RemoteCodexBarSnapshotError.responseTooLarge) {
            try await RemoteCodexBarSnapshotClient(transport: transport).fetch(configuration: remoteConfiguration)
        }
        #expect(RemoteCodexBarOversizedURLProtocol.requestCount == 1)
    }

    @Test
    func `production transport blocks bearer redirects to another origin`() throws {
        var redirect = try URLRequest(url: #require(URL(string: "https://attacker.example/capture")))
        redirect.setValue("Bearer secret-value", forHTTPHeaderField: "Authorization")

        #expect(RemoteCodexBarBoundedHTTPTransport.guardedRedirectRequest(
            originalURL: URL(string: "https://server.example/dashboard/v1/snapshot"),
            redirectRequest: redirect) == nil)
    }

    @MainActor
    @Test
    func `editing the endpoint clears the token before publishing the new server`() {
        let tokens = InMemoryRemoteCodexBarTokenStore()
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-endpoint-token-scope",
            remoteCodexBarTokenStore: tokens)
        settings.applyRemoteCodexBarConfiguration(
            serverURL: "https://server-a.example.com",
            bearerToken: "server-a-token")

        settings.remoteCodexBarServerURL = "https://server-b.example.com"

        #expect(settings.remoteCodexBarBearerToken.isEmpty)
        #expect(settings.remoteCodexBarConfiguration == nil)
        #expect(tokens.storedValues == ["server-a-token", ""])
    }

    @MainActor
    @Test
    func `refresh preserves same-server data but clears data from a replaced endpoint`() async {
        let settings = testSettingsStore(suiteName: "RemoteCodexBarSnapshotTests-refresh-failure")
        settings.remoteCodexBarServerURL = "https://new.example.com"
        settings.remoteCodexBarBearerToken = "token"
        let failingTransport = ProviderHTTPTransportHandler { _ in
            throw URLError(.notConnectedToInternet)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            remoteCodexBarClient: RemoteCodexBarSnapshotClient(transport: failingTransport))
        let retained = AccountSnapshotSyncPayload(
            provider: UsageProvider.codex.instanceID,
            deviceID: "remote-codexbar",
            accountIdentity: "person@example.com",
            displayLabel: "Remote account",
            usage: UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: .now))
        let newConfigurationID = settings.remoteCodexBarConfiguration?.configurationID

        store.remoteCodexBarSnapshots = [retained]
        store.remoteCodexBarSnapshotConfigurationID = newConfigurationID
        await store.refreshRemoteCodexBarSnapshot()
        #expect(store.remoteCodexBarSnapshots.map(\.recordName) == [retained.recordName])
        #expect(store.remoteCodexBarError != nil)

        store.remoteCodexBarSnapshots = [retained]
        settings.remoteCodexBarBearerToken = "replacement-token"
        await store.refreshRemoteCodexBarSnapshot()
        #expect(store.remoteCodexBarSnapshots.isEmpty)
        #expect(store.remoteCodexBarSnapshotConfigurationID != newConfigurationID)

        store.remoteCodexBarSnapshots = [retained]
        settings.remoteCodexBarServerURL = "https://replacement.example.com"
        await store.refreshRemoteCodexBarSnapshot()
        #expect(store.remoteCodexBarSnapshots.isEmpty)
    }

    @MainActor
    @Test
    func `temporarily unavailable token retries without restarting the app`() {
        let tokens = RetryingRemoteCodexBarTokenStore(value: "saved-token")
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-token-retry",
            remoteCodexBarTokenStore: tokens)
        #expect(settings.remoteCodexBarBearerToken.isEmpty)
        #expect(settings.remoteCodexBarSecretError != nil)

        settings.retryRemoteCodexBarTokenLoadIfNeeded()
        #expect(settings.remoteCodexBarBearerToken == "saved-token")
        #expect(settings.remoteCodexBarSecretError == nil)
        #expect(tokens.loadAttempts == 2)
    }

    @MainActor
    @Test
    func `scheduled remote refresh starts without joining the local refresh wait`() async {
        let settings = testSettingsStore(suiteName: "RemoteCodexBarSnapshotTests-scheduled-refresh")
        settings.remoteCodexBarServerURL = "https://example.com"
        settings.remoteCodexBarBearerToken = "token"
        let slowTransport = ProviderHTTPTransportHandler { _ in
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            remoteCodexBarClient: RemoteCodexBarSnapshotClient(transport: slowTransport))

        store.scheduleRemoteCodexBarRefresh()
        #expect(store.remoteCodexBarRefreshInFlight)
        let task = store.remoteCodexBarRefreshTask
        #expect(task != nil)
        task?.cancel()
        await task?.value
    }

    @MainActor
    @Test
    func `remote projection enters the existing fleet card display seam`() throws {
        let settings = testSettingsStore(suiteName: "RemoteCodexBarSnapshotTests-display")
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: .now)
        store.remoteCodexBarSnapshots = [AccountSnapshotSyncPayload(
            provider: UsageProvider.codex.instanceID,
            deviceID: "remote-codexbar",
            accountIdentity: "remote|codex|default",
            displayLabel: "Remote account",
            usage: usage)]

        try withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
            let projection = controller.fleetAccountProjection(for: .codex)
            let remote = try #require(projection.fallback ?? projection.additionalAccounts.first)
            let model = try #require(controller.fleetAccountMenuCardModel(remote))
            #expect(model.subtitleText.contains("remote CodexBar"))
        }
    }

    private static let snapshotJSON = """
    {
      "schemaVersion": 1,
      "generatedAt": "2026-08-28T20:00:00Z",
      "staleAfterSeconds": 180,
      "unknownTopLevel": true,
      "providers": [{
        "id": "codex",
        "name": "Codex",
        "enabled": true,
        "source": "oauth",
        "identity": {"accountEmail": "person@example.com", "plan": "Plus"},
        "windows": [
          {"kind": "session", "label": "Session", "usedPercent": 25, "remainingPercent": 75, "resetAt": null},
          {"kind": "weekly", "label": "Weekly", "usedPercent": 60, "remainingPercent": 40,
           "resetAt": "2026-09-01T00:00:00Z"},
          {"kind": "spark", "label": "Spark", "usedPercent": 10, "remainingPercent": 90, "resetAt": null},
          {"kind": "idle", "label": "Idle", "usedPercent": 0, "remainingPercent": 100, "resetAt": null, "idle": true}
        ],
        "credits": {"remaining": 12.5, "unit": "credits"},
        "cost": {"todayUSD": 1.25, "last30DaysUSD": 18.75},
        "display": {"accentColor": "#000000", "sortKey": 0, "priority": "normal"},
        "error": null,
        "updatedAt": "2026-08-28T20:00:00Z",
        "accounts": [{
          "id": "slot:1",
          "label": "Work",
          "active": true,
          "identity": {"accountEmail": "work@example.com", "plan": null},
          "windows": [{"kind": "session", "label": "Session", "usedPercent": 15,
                       "remainingPercent": 85, "resetAt": null}],
          "pace": null,
          "error": null,
          "updatedAt": "2026-08-28T19:59:00Z"
        }]
      }]
    }
    """
}

private final class RemoteCodexBarOversizedURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requestCountStorage = 0

    static var requestCount: Int {
        self.lock.withLock { self.requestCountStorage }
    }

    static func reset() {
        self.lock.withLock { self.requestCountStorage = 0 }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.requestCountStorage += 1 }
        guard let url = self.request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 503,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil)
        else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 64))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
