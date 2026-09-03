import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

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

        let tailscaleHTTP = try #require(RemoteCodexBarConfiguration.resolve(
            serverURL: "http://100.100.10.20:9876",
            bearerToken: "token",
            allowsPlainHTTP: true))
        #expect(tailscaleHTTP.snapshotURL.absoluteString == "http://100.100.10.20:9876/dashboard/v1/snapshot")
        #expect(ProviderEndpointOverrideValidator().validatedURLAllowingPrivateNetworkHTTP(
            "http://100.100.10.20:9876") == nil)
        #expect(RemoteCodexBarConfiguration.requiresPlainHTTPConsent(
            serverURL: "http://100.100.10.20:9876"))
        #expect(RemoteCodexBarConfiguration.resolve(
            serverURL: "http://100.100.10.20:9876",
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
    func `client sends bearer auth decodes schema v1 and projects account cards over ambient provider`() async throws {
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
        #expect(projection.snapshots.count == 1)
        #expect(projection.providerIDs == [.codex])
        #expect(projection.primarySnapshots[.codex]?.primary?.usedPercent == 15)
        let account = try #require(projection.snapshots.first)
        #expect(account.provider == UsageProvider.codex.instanceID)
        #expect(account.accountKey == AccountSnapshotSyncPayload.accountKey(for: "work@example.com"))
        #expect(account.displayLabel == "Work")
        #expect(account.usage.primary?.usedPercent == 15)
    }

    @MainActor
    @Test
    func `remote only mode uses served provider inventory and disables local background providers`() async {
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-remote-only",
            remoteCodexBarTokenStore: InMemoryRemoteCodexBarTokenStore(value: RemoteCodexBarStoredCredential(
                serverURL: "https://example.com",
                bearerToken: "token",
                allowsPlainHTTP: false)))
        let remoteTransport = ProviderHTTPTransportHandler { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(Self.snapshotJSON.utf8), response)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            remoteCodexBarClient: RemoteCodexBarSnapshotClient(transport: remoteTransport))
        store.remoteCodexBarProviderIDs = [.codex, .claude]
        store.remoteCodexBarPrimarySnapshots[.codex] = UsageSnapshot(
            primary: .init(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: .init(
                providerID: .codex,
                accountEmail: "remote@example.com",
                accountOrganization: nil,
                loginMethod: "Plus"))

        settings.remoteCodexBarRemoteOnlyEnabled = true

        #expect(settings.usesRemoteCodexBarProvidersOnly)
        #expect(store.enabledProvidersForDisplay() == [.codex, .claude])
        #expect(store.enabledProvidersForBackgroundWork().isEmpty)
        #expect(store.snapshot(for: .codex)?.identity?.accountEmail == "remote@example.com")
        #expect(store.isEnabled(.claude))

        var performedLocalRefresh = false
        store._test_providerRefreshOverride = { _ in performedLocalRefresh = true }
        await store.refreshProvider(.codex)
        #expect(!performedLocalRefresh)
        #expect(store.remoteCodexBarPrimarySnapshots[.codex]?.identity?.accountEmail == "person@example.com")

        settings.applyRemoteCodexBarConfiguration(serverURL: "", bearerToken: "")
        #expect(!settings.remoteCodexBarRemoteOnlyEnabled)
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
        let tokens = InMemoryRemoteCodexBarTokenStore(value: RemoteCodexBarStoredCredential(
            serverURL: "https://saved.example.com",
            bearerToken: "saved-token",
            allowsPlainHTTP: false))
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-settings",
            remoteCodexBarTokenStore: tokens)
        #expect(settings.remoteCodexBarServerURL == "https://saved.example.com")
        #expect(settings.remoteCodexBarBearerToken == "saved-token")

        settings.applyRemoteCodexBarConfiguration(
            serverURL: "https://example.com",
            bearerToken: "new-token")
        #expect(settings.userDefaults.string(forKey: "remoteCodexBarServerURL") == "https://example.com")
        #expect(settings.userDefaults.string(forKey: "remoteCodexBarBearerToken") == nil)
        #expect(tokens.storedValues.compactMap(\.self).map(\.bearerToken) == ["new-token"])
        #expect(settings.remoteCodexBarConfiguration?.bearerToken == "new-token")
    }

    @MainActor
    @Test
    func `startup trusts the endpoint bound to the Keychain credential`() {
        let tokens = InMemoryRemoteCodexBarTokenStore(value: RemoteCodexBarStoredCredential(
            serverURL: "https://server-b.example.com",
            bearerToken: "server-b-token",
            allowsPlainHTTP: false))
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-interrupted-replacement",
            remoteCodexBarTokenStore: tokens,
            prepareDefaults: { defaults in
                defaults.set("https://server-a.example.com", forKey: "remoteCodexBarServerURL")
            })

        #expect(settings.remoteCodexBarServerURL == "https://server-b.example.com")
        #expect(settings.remoteCodexBarBearerToken == "server-b-token")
        #expect(settings.remoteCodexBarConfiguration?.snapshotURL.host == "server-b.example.com")
        #expect(settings.userDefaults.string(forKey: "remoteCodexBarServerURL") ==
            "https://server-b.example.com")
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
        let loadedCredential = try tokens.loadCredential()
        let durableCredential = try #require(loadedCredential)
        #expect(durableCredential.serverURL == "https://server-a.example.com")
        #expect(durableCredential.bearerToken == "server-a-token")

        let persisted = try #require(RemoteCodexBarConfiguration.resolve(
            serverURL: durableCredential.serverURL,
            bearerToken: durableCredential.bearerToken,
            allowsPlainHTTP: durableCredential.allowsPlainHTTP))
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

    @MainActor
    @Test
    func `failed initial token save connects for the current session only`() throws {
        let tokens = FailingRemoteCodexBarTokenStore()
        tokens.failWrites = true
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-failed-initial-token-save",
            remoteCodexBarTokenStore: tokens)

        #expect(settings.applyRemoteCodexBarConfiguration(
            serverURL: "https://server.example.com",
            bearerToken: "session-token"))
        #expect(settings.remoteCodexBarConfiguration != nil)
        #expect(settings.remoteCodexBarServerURL == "https://server.example.com")
        #expect(settings.remoteCodexBarBearerToken == "session-token")
        #expect(settings.userDefaults.string(forKey: "remoteCodexBarServerURL") ==
            "https://server.example.com")
        #expect(settings.remoteCodexBarSecretError?.contains("Connected for this session only") == true)
        #expect(try tokens.loadCredential() == nil)
    }

    @MainActor
    @Test
    func `failed token deletion disconnects the session but preserves durable authority`() throws {
        let durableCredential = RemoteCodexBarStoredCredential(
            serverURL: "https://server.example.com",
            bearerToken: "durable-token",
            allowsPlainHTTP: false)
        let tokens = FailingRemoteCodexBarTokenStore(value: durableCredential)
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-failed-token-deletion",
            remoteCodexBarTokenStore: tokens)
        settings.remoteCodexBarRemoteOnlyEnabled = true
        tokens.failWrites = true

        #expect(settings.applyRemoteCodexBarConfiguration(serverURL: "", bearerToken: ""))
        #expect(settings.remoteCodexBarConfiguration == nil)
        #expect(settings.remoteCodexBarServerURL.isEmpty)
        #expect(settings.remoteCodexBarBearerToken.isEmpty)
        #expect(!settings.remoteCodexBarRemoteOnlyEnabled)
        #expect(settings.remoteCodexBarSecretError?.contains("saved Keychain item could not be removed") == true)
        #expect(try tokens.loadCredential() == durableCredential)

        let restarted = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-failed-token-deletion-restart",
            remoteCodexBarTokenStore: tokens)
        #expect(restarted.remoteCodexBarServerURL == durableCredential.serverURL)
        #expect(restarted.remoteCodexBarBearerToken == durableCredential.bearerToken)
        #expect(restarted.remoteCodexBarConfiguration != nil)
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

    @Test
    func `production transport propagates task cancellation to the URL session request`() async throws {
        RemoteCodexBarCancellableURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteCodexBarCancellableURLProtocol.self]
        let transport = RemoteCodexBarBoundedHTTPTransport(
            maximumResponseBytes: 32,
            configuration: configuration)
        let request = try URLRequest(url: #require(URL(string: "https://example.com/dashboard/v1/snapshot")))
        let task = Task { try await transport.data(for: request) }

        let deadline = ContinuousClock.now + .seconds(1)
        while RemoteCodexBarCancellableURLProtocol.requestCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(RemoteCodexBarCancellableURLProtocol.requestCount == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        let cancellationDeadline = ContinuousClock.now + .seconds(1)
        while RemoteCodexBarCancellableURLProtocol.cancelCount == 0,
              ContinuousClock.now < cancellationDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(RemoteCodexBarCancellableURLProtocol.cancelCount == 1)

        let cancelledBeforeStart = Task { try await transport.data(for: request) }
        cancelledBeforeStart.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledBeforeStart.value
        }
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
        #expect(tokens.storedValues.count == 2)
        #expect(tokens.storedValues[0]?.bearerToken == "server-a-token")
        #expect(tokens.storedValues[1] == nil)
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
    func `permanent remote failure clears same-server last-good data`() async {
        let settings = testSettingsStore(suiteName: "RemoteCodexBarSnapshotTests-permanent-failure")
        settings.remoteCodexBarServerURL = "https://example.com"
        settings.remoteCodexBarBearerToken = "revoked-token"
        let unauthorizedTransport = ProviderHTTPTransportHandler { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            remoteCodexBarClient: RemoteCodexBarSnapshotClient(transport: unauthorizedTransport))
        store.remoteCodexBarSnapshots = [AccountSnapshotSyncPayload(
            provider: UsageProvider.codex.instanceID,
            deviceID: "remote-codexbar",
            accountIdentity: "person@example.com",
            displayLabel: "Stale remote account",
            usage: UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: .now))]
        store.remoteCodexBarSnapshotConfigurationID = settings.remoteCodexBarConfiguration?.configurationID

        await store.refreshRemoteCodexBarSnapshot()

        #expect(store.remoteCodexBarSnapshots.isEmpty)
        #expect(store.remoteCodexBarError == RemoteCodexBarSnapshotError.unauthorized.localizedDescription)
        #expect(RemoteCodexBarSnapshotError.httpStatus(503).preservesLastGoodSnapshot)
        #expect(!RemoteCodexBarSnapshotError.unsupportedSchema(2).preservesLastGoodSnapshot)
    }

    @MainActor
    @Test
    func `temporarily unavailable token retries without restarting the app`() {
        let tokens = RetryingRemoteCodexBarTokenStore(value: RemoteCodexBarStoredCredential(
            serverURL: "https://saved.example.com",
            bearerToken: "saved-token",
            allowsPlainHTTP: false))
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-token-retry",
            remoteCodexBarTokenStore: tokens)
        #expect(settings.remoteCodexBarBearerToken.isEmpty)
        #expect(settings.remoteCodexBarSecretError != nil)

        settings.retryRemoteCodexBarTokenLoadIfNeeded()
        #expect(settings.remoteCodexBarServerURL == "https://saved.example.com")
        #expect(settings.remoteCodexBarBearerToken == "saved-token")
        #expect(settings.remoteCodexBarSecretError == nil)
        #expect(tokens.loadAttempts == 2)
    }

    @MainActor
    @Test
    func `re-enabling Keychain access reloads the saved remote credential`() {
        let previousOverride = KeychainAccessGate.currentOverrideForTesting
        defer {
            if let previousOverride {
                KeychainAccessGate.isDisabled = previousOverride
            } else {
                KeychainAccessGate.resetOverrideForTesting()
            }
        }
        let tokens = KeychainGateAwareRemoteCodexBarTokenStore(value: RemoteCodexBarStoredCredential(
            serverURL: "https://saved.example.com",
            bearerToken: "saved-token",
            allowsPlainHTTP: false))
        let settings = testSettingsStore(
            suiteName: "RemoteCodexBarSnapshotTests-keychain-reenabled",
            remoteCodexBarTokenStore: tokens,
            prepareDefaults: { $0.set(true, forKey: "debugDisableKeychainAccess") })
        #expect(settings.remoteCodexBarBearerToken.isEmpty)
        #expect(tokens.loadAttempts == 1)

        settings.retryRemoteCodexBarTokenLoadIfNeeded()
        #expect(tokens.loadAttempts == 1)
        settings.debugDisableKeychainAccess = false

        #expect(settings.remoteCodexBarServerURL == "https://saved.example.com")
        #expect(settings.remoteCodexBarBearerToken == "saved-token")
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
        settings.remoteCodexBarServerURL = "https://example.com"
        settings.remoteCodexBarBearerToken = "token"
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: .now,
            identity: ProviderIdentitySnapshot(
                providerID: UsageProvider.codex.instanceID,
                accountEmail: "person@example.com",
                accountOrganization: nil,
                loginMethod: "Plus"))
        store.remoteCodexBarSnapshots = [AccountSnapshotSyncPayload(
            provider: UsageProvider.codex.instanceID,
            deviceID: "remote-codexbar",
            accountIdentity: "remote|codex|default",
            displayLabel: "Remote account",
            usage: usage)]
        store.remoteCodexBarSnapshotConfigurationID = settings.remoteCodexBarConfiguration?.configurationID

        try withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
            let projection = controller.fleetAccountProjection(for: .codex)
            let remote = try #require(projection.fallback ?? projection.additionalAccounts.first)
            let model = try #require(controller.fleetAccountMenuCardModel(remote))
            #expect(model.subtitleText.contains("remote CodexBar"))
            #expect(model.email == "Remote account")

            #expect(settings.applyRemoteCodexBarConfiguration(serverURL: "", bearerToken: ""))
            let disconnected = controller.fleetAccountProjection(for: .codex)
            #expect(disconnected.fallback == nil)
            #expect(disconnected.additionalAccounts.isEmpty)
        }
    }

    @Test
    func `redacted accounts use stable server scoped ids`() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(RemoteCodexBarSnapshot.self, from: Data(Self.redactedAccountsJSON.utf8))
        let serverURL = try #require(URL(string: "https://server.example/dashboard/v1/snapshot"))

        let projection = RemoteCodexBarProjection.make(snapshot: snapshot, serverURL: serverURL)
        #expect(projection.snapshots.count == 2)
        #expect(Set(projection.snapshots.map(\.accountKey)).count == 2)
        #expect(Set(projection.snapshots.map(\.accountKey)) == Set([
            AccountSnapshotSyncPayload.accountKey(
                for: "https://server.example/dashboard/v1/snapshot|codex|slot:1"),
            AccountSnapshotSyncPayload.accountKey(
                for: "https://server.example/dashboard/v1/snapshot|codex|slot:2"),
        ]))
        #expect(Set(projection.snapshots.map(\.displayLabel)) == Set(["Personal", "Work"]))
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

    private static let redactedAccountsJSON = """
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
            "active": true,
            "identity": {"accountEmail": "redacted@example.com", "plan": null},
            "windows": [{"kind": "session", "label": "Session", "usedPercent": 15,
                         "remainingPercent": 85, "resetAt": null}]
          },
          {
            "id": "slot:2",
            "label": "Work",
            "active": false,
            "identity": {"accountEmail": "redacted@example.com", "plan": null},
            "windows": [{"kind": "session", "label": "Session", "usedPercent": 35,
                         "remainingPercent": 65, "resetAt": null}]
          }
        ]
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

private final class RemoteCodexBarCancellableURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requestCountStorage = 0
    private nonisolated(unsafe) static var cancelCountStorage = 0

    static var requestCount: Int {
        self.lock.withLock { self.requestCountStorage }
    }

    static var cancelCount: Int {
        self.lock.withLock { self.cancelCountStorage }
    }

    static func reset() {
        self.lock.withLock {
            self.requestCountStorage = 0
            self.cancelCountStorage = 0
        }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.requestCountStorage += 1 }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.cancelCountStorage += 1 }
    }
}
