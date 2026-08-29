import CodexBarCore
import Foundation

struct RemoteCodexBarConfiguration: Equatable, Sendable {
    let snapshotURL: URL
    let bearerToken: String

    var configurationID: String {
        let tokenFingerprint = CanonicalSyncJSON.hash(data: Data(self.bearerToken.utf8))
        return "\(self.snapshotURL.absoluteString)|\(tokenFingerprint)"
    }

    static func resolve(
        serverURL: String,
        bearerToken: String,
        allowsPlainHTTP: Bool = false) -> Self?
    {
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let validator = ProviderEndpointOverrideValidator()
        let normalizedServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              !validator.requiresExplicitPlainHTTPConsent(normalizedServerURL) || allowsPlainHTTP,
              var components = validator
                  .validatedURLAllowingPrivateNetworkHTTP(normalizedServerURL)
                  .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
                  components.query == nil,
                  components.fragment == nil
        else { return nil }

        let endpointPath = "/dashboard/v1/snapshot"
        let trimmedPath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        if trimmedPath.hasSuffix(endpointPath) {
            components.path = trimmedPath
        } else {
            components.path = trimmedPath + endpointPath
        }
        guard let url = components.url else { return nil }
        return Self(snapshotURL: url, bearerToken: token)
    }

    static func requiresPlainHTTPConsent(serverURL: String) -> Bool {
        ProviderEndpointOverrideValidator().requiresExplicitPlainHTTPConsent(
            serverURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum RemoteCodexBarSnapshotError: LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case httpStatus(Int)
    case responseTooLarge
    case unsupportedSchema(Int)
    case invalidSnapshot

    var preservesLastGoodSnapshot: Bool {
        switch self {
        case let .httpStatus(status):
            status == 408 || status == 429 || (500...599).contains(status)
        case .invalidResponse, .unauthorized, .responseTooLarge, .unsupportedSchema, .invalidSnapshot:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Remote CodexBar returned an invalid response."
        case .unauthorized: "Remote CodexBar rejected the bearer token."
        case let .httpStatus(status): "Remote CodexBar returned HTTP \(status)."
        case .responseTooLarge: "Remote CodexBar returned an unexpectedly large snapshot."
        case let .unsupportedSchema(version): "Remote CodexBar schema \(version) is not supported."
        case .invalidSnapshot: "Remote CodexBar returned an invalid schema-v1 snapshot."
        }
    }
}

struct RemoteCodexBarSnapshotClient: Sendable {
    static let maximumResponseBytes = 2 * 1024 * 1024

    let transport: any ProviderHTTPTransport

    init() {
        self.transport = RemoteCodexBarBoundedHTTPTransport(maximumResponseBytes: Self.maximumResponseBytes)
    }

    init(transport: any ProviderHTTPTransport) {
        self.transport = transport
    }

    func fetch(configuration: RemoteCodexBarConfiguration) async throws -> RemoteCodexBarSnapshot {
        var request = URLRequest(
            url: configuration.snapshotURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await self.transport.response(for: request, retryPolicy: .transientIdempotent)
        guard response.data.count <= Self.maximumResponseBytes else {
            throw RemoteCodexBarSnapshotError.responseTooLarge
        }
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw RemoteCodexBarSnapshotError.unauthorized
        default:
            throw RemoteCodexBarSnapshotError.httpStatus(response.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot: RemoteCodexBarSnapshot
        do {
            snapshot = try decoder.decode(RemoteCodexBarSnapshot.self, from: response.data)
        } catch {
            throw RemoteCodexBarSnapshotError.invalidSnapshot
        }
        guard snapshot.schemaVersion == 1 else {
            throw RemoteCodexBarSnapshotError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot
    }
}

final class RemoteCodexBarBoundedHTTPTransport: NSObject, ProviderHTTPTransport, URLSessionDataDelegate,
    @unchecked Sendable
{
    private struct RequestState {
        var data = Data()
        var response: URLResponse?
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
    }

    private final class RequestCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var isCancelled = false

        func install(_ task: URLSessionDataTask) -> Bool {
            self.lock.withLock {
                guard !self.isCancelled else { return false }
                self.task = task
                return true
            }
        }

        func cancel() {
            let task = self.lock.withLock {
                self.isCancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    private let maximumResponseBytes: Int
    private let lock = NSLock()
    private var states: [Int: RequestState] = [:]
    private let configuration: URLSessionConfiguration
    private lazy var session = URLSession(configuration: self.configuration, delegate: self, delegateQueue: nil)

    init(
        maximumResponseBytes: Int,
        configuration: URLSessionConfiguration? = nil)
    {
        self.maximumResponseBytes = maximumResponseBytes
        let resolvedConfiguration = configuration ?? URLSessionConfiguration.ephemeral
        resolvedConfiguration.httpCookieStorage = nil
        resolvedConfiguration.httpShouldSetCookies = false
        resolvedConfiguration.urlCredentialStorage = nil
        resolvedConfiguration.urlCache = nil
        resolvedConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        resolvedConfiguration.timeoutIntervalForRequest = 30
        resolvedConfiguration.timeoutIntervalForResource = 30
        self.configuration = resolvedConfiguration
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let cancellation = RequestCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = self.session.dataTask(with: request)
                guard cancellation.install(task) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.lock.withLock {
                    self.states[task.taskIdentifier] = RequestState(continuation: continuation)
                }
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(Self.guardedRedirectRequest(
            originalURL: task.originalRequest?.url,
            redirectRequest: request))
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        if response.expectedContentLength > Int64(self.maximumResponseBytes) {
            completionHandler(.cancel)
            self.finish(
                taskIdentifier: dataTask.taskIdentifier,
                result: .failure(RemoteCodexBarSnapshotError.responseTooLarge))
            return
        }
        self.lock.withLock { self.states[dataTask.taskIdentifier]?.response = response }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = self.lock.withLock {
            guard var state = self.states[dataTask.taskIdentifier] else { return false }
            guard data.count <= self.maximumResponseBytes - state.data.count else { return true }
            state.data.append(data)
            self.states[dataTask.taskIdentifier] = state
            return false
        }
        guard exceeded else { return }
        dataTask.cancel()
        self.finish(
            taskIdentifier: dataTask.taskIdentifier,
            result: .failure(RemoteCodexBarSnapshotError.responseTooLarge))
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let resolvedError: Error = if (error as? URLError)?.code == .cancelled {
                CancellationError()
            } else {
                error
            }
            self.finish(taskIdentifier: task.taskIdentifier, result: .failure(resolvedError))
            return
        }
        let result: Result<(Data, URLResponse), Error> = self.lock.withLock {
            guard let state = self.states[task.taskIdentifier], let response = state.response else {
                return .failure(URLError(.badServerResponse))
            }
            return .success((state.data, response))
        }
        self.finish(taskIdentifier: task.taskIdentifier, result: result)
    }

    private func finish(taskIdentifier: Int, result: Result<(Data, URLResponse), Error>) {
        let continuation = self.lock.withLock { self.states.removeValue(forKey: taskIdentifier)?.continuation }
        continuation?.resume(with: result)
    }

    static func guardedRedirectRequest(originalURL: URL?, redirectRequest request: URLRequest) -> URLRequest? {
        guard let originalURL, let redirectedURL = request.url else { return nil }
        guard originalURL.scheme?.caseInsensitiveCompare(redirectedURL.scheme ?? "") == .orderedSame else {
            return nil
        }
        guard originalURL.host?.caseInsensitiveCompare(redirectedURL.host ?? "") == .orderedSame else {
            return nil
        }
        guard self.normalizedPort(originalURL) == self.normalizedPort(redirectedURL) else { return nil }
        return request
    }

    private static func normalizedPort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

struct RemoteCodexBarSnapshot: Decodable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let staleAfterSeconds: Int
    let providers: [Provider]

    struct Provider: Decodable, Sendable {
        let id: String
        let name: String
        let enabled: Bool
        let source: String?
        let status: Status?
        let identity: Identity?
        let windows: [Window]
        let credits: Credits?
        let cost: Cost?
        let error: RemoteError?
        let updatedAt: Date?
        let accounts: [Account]
        let accountsError: String?

        private enum CodingKeys: String, CodingKey {
            case id, name, enabled, source, status, identity, windows, credits, cost, error, updatedAt, accounts
            case accountsError
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? self.id
            self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            self.source = try container.decodeIfPresent(String.self, forKey: .source)
            self.status = try container.decodeIfPresent(Status.self, forKey: .status)
            self.identity = try container.decodeIfPresent(Identity.self, forKey: .identity)
            self.windows = try container.decodeIfPresent([Window].self, forKey: .windows) ?? []
            self.credits = try container.decodeIfPresent(Credits.self, forKey: .credits)
            self.cost = try container.decodeIfPresent(Cost.self, forKey: .cost)
            self.error = try container.decodeIfPresent(RemoteError.self, forKey: .error)
            self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            self.accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
            self.accountsError = try container.decodeIfPresent(String.self, forKey: .accountsError)
        }
    }

    struct Account: Decodable, Sendable {
        let id: String
        let label: String
        let active: Bool
        let identity: Identity?
        let windows: [Window]
        let error: String?
        let updatedAt: Date?
    }

    struct Status: Decodable, Sendable {
        let level: String
        let label: String
        let updatedAt: Date?
    }

    struct Identity: Decodable, Sendable {
        let accountEmail: String?
        let plan: String?
    }

    struct Window: Decodable, Sendable {
        let kind: String
        let label: String
        let usedPercent: Double
        let resetAt: Date?
        let idle: Bool?
    }

    struct Credits: Decodable, Sendable {
        let remaining: Double
        let unit: String
    }

    struct Cost: Decodable, Sendable {
        let todayUSD: Double?
        let last30DaysUSD: Double?
    }

    struct RemoteError: Decodable, Sendable {
        let message: String
    }
}

struct RemoteCodexBarProjection: Sendable {
    let snapshots: [AccountSnapshotSyncPayload]

    static func make(
        snapshot: RemoteCodexBarSnapshot,
        serverURL: URL) -> Self
    {
        let serverIdentity = serverURL.absoluteString
        var projected: [AccountSnapshotSyncPayload] = []
        for row in snapshot.providers where row.enabled {
            guard let provider = UsageProvider(rawValue: row.id) else { continue }
            let providerIdentity = row.identity?.accountEmail
                ?? "\(serverIdentity)|\(row.id)|default"
            if row.accounts.isEmpty,
               let usage = self.usageSnapshot(
                   provider: provider,
                   windows: row.windows,
                   identity: row.identity,
                   status: row.status,
                   credits: row.credits,
                   cost: row.cost,
                   error: row.error?.message ?? row.accountsError,
                   updatedAt: row.updatedAt ?? snapshot.generatedAt)
            {
                projected.append(AccountSnapshotSyncPayload(
                    provider: provider.instanceID,
                    deviceID: "remote-codexbar",
                    accountIdentity: providerIdentity,
                    displayLabel: row.identity?.accountEmail ?? row.name,
                    usage: usage))
            }

            for account in row.accounts {
                guard let usage = self.usageSnapshot(
                    provider: provider,
                    windows: account.windows,
                    identity: account.identity,
                    status: nil,
                    credits: nil,
                    cost: nil,
                    error: account.error,
                    updatedAt: account.updatedAt ?? row.updatedAt ?? snapshot.generatedAt)
                else { continue }
                projected.append(AccountSnapshotSyncPayload(
                    provider: provider.instanceID,
                    deviceID: "remote-codexbar",
                    accountIdentity: self.accountIdentity(
                        account,
                        in: row.accounts,
                        providerID: row.id,
                        serverIdentity: serverIdentity),
                    displayLabel: account.label,
                    usage: usage))
            }
        }
        return Self(snapshots: projected)
    }

    private static func accountIdentity(
        _ account: RemoteCodexBarSnapshot.Account,
        in accounts: [RemoteCodexBarSnapshot.Account],
        providerID: String,
        serverIdentity: String) -> String
    {
        let email = account.identity?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailLocalPart = email.flatMap { $0.split(separator: "@", maxSplits: 1).first.map(String.init) }
        let isRedactedEmail = emailLocalPart?.caseInsensitiveCompare("redacted") == .orderedSame
        if let email, !email.isEmpty, !isRedactedEmail {
            let matchingEmailCount = accounts.count {
                let candidate = $0.identity?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
                return candidate?.caseInsensitiveCompare(email) == .orderedSame
            }
            if matchingEmailCount == 1 {
                return email
            }
        }
        return "\(serverIdentity)|\(providerID)|\(account.id)"
    }

    // Projection stays explicit because each server field has a distinct display fallback.
    // swiftlint:disable:next function_parameter_count
    private static func usageSnapshot(
        provider: UsageProvider,
        windows: [RemoteCodexBarSnapshot.Window],
        identity: RemoteCodexBarSnapshot.Identity?,
        status: RemoteCodexBarSnapshot.Status?,
        credits: RemoteCodexBarSnapshot.Credits?,
        cost: RemoteCodexBarSnapshot.Cost?,
        error: String?,
        updatedAt: Date) -> UsageSnapshot?
    {
        let visibleWindows = windows.filter { $0.idle != true && $0.usedPercent.isFinite }
        let primary = visibleWindows.first(where: { $0.kind == "session" }).map(self.rateWindow)
        let secondary = visibleWindows.first(where: { $0.kind == "weekly" }).map(self.rateWindow)
        let tertiary = visibleWindows.first(where: { $0.kind == "tertiary" }).map(self.rateWindow)
        let standardKinds: Set = ["session", "weekly", "tertiary"]
        let extras = visibleWindows.filter { !standardKinds.contains($0.kind) }.map { window in
            NamedRateWindow(id: window.kind, title: window.label, window: self.rateWindow(window))
        }
        let details = self.details(status: status, credits: credits, cost: cost, error: error)
        guard primary != nil || secondary != nil || tertiary != nil || !extras.isEmpty || !details.isEmpty else {
            return nil
        }
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extras.isEmpty ? nil : extras,
            details: details,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: provider.instanceID,
                accountEmail: identity?.accountEmail,
                accountOrganization: nil,
                loginMethod: identity?.plan),
            dataConfidence: .percentOnly)
    }

    private static func rateWindow(_ window: RemoteCodexBarSnapshot.Window) -> RateWindow {
        RateWindow(
            usedPercent: min(100, max(0, window.usedPercent)),
            windowMinutes: nil,
            resetsAt: window.resetAt,
            resetDescription: nil)
    }

    private static func details(
        status: RemoteCodexBarSnapshot.Status?,
        credits: RemoteCodexBarSnapshot.Credits?,
        cost: RemoteCodexBarSnapshot.Cost?,
        error: String?) -> [ProviderDetailSection]
    {
        var rows: [ProviderDetailSection.Row] = []
        if let status, !status.label.isEmpty {
            if let row = try? ProviderDetailSection.Row(label: "Status", value: status.label) {
                rows.append(row)
            }
        }
        if let credits, credits.remaining.isFinite {
            if let row = try? ProviderDetailSection.Row(
                label: "Credits remaining",
                value: "\(credits.remaining) \(credits.unit)")
            {
                rows.append(row)
            }
        }
        if let today = cost?.todayUSD, today.isFinite {
            if let row = try? ProviderDetailSection.Row(label: "Today", value: String(format: "$%.2f", today)) {
                rows.append(row)
            }
        }
        if let month = cost?.last30DaysUSD, month.isFinite {
            if let row = try? ProviderDetailSection.Row(
                label: "Last 30 days",
                value: String(format: "$%.2f", month))
            {
                rows.append(row)
            }
        }
        if let error = error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            if let row = try? ProviderDetailSection.Row(label: "Remote error", value: error) {
                rows.append(row)
            }
        }
        guard !rows.isEmpty, let section = try? ProviderDetailSection(title: "Remote CodexBar", rows: rows) else {
            return []
        }
        return [section]
    }
}
