import CodexBarCore
import Foundation

struct RemoteCodexBarConfiguration: Equatable, Sendable {
    let snapshotURL: URL
    let bearerToken: String

    var configurationID: String {
        let tokenFingerprint = CanonicalSyncJSON.hash(data: Data(self.bearerToken.utf8))
        return "\(self.snapshotURL.absoluteString)|\(tokenFingerprint)"
    }

    static func resolve(serverURL: String, bearerToken: String) -> Self? {
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              var components = ProviderEndpointOverrideValidator()
                  .validatedURLAllowingPrivateNetworkHTTP(serverURL.trimmingCharacters(in: .whitespacesAndNewlines))
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
}

enum RemoteCodexBarSnapshotError: LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case httpStatus(Int)
    case responseTooLarge
    case unsupportedSchema(Int)
    case invalidSnapshot

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

    init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
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
            if let usage = self.usageSnapshot(
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
                    accountIdentity: account.identity?.accountEmail ?? account.id,
                    displayLabel: account.label,
                    usage: usage))
            }
        }
        return Self(snapshots: projected)
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
