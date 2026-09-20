import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

/// Covers the generic (non claude-swap) multi-account dashboard projection: one
/// provider row carrying every enumerated account, with the serving Mac's
/// selected account marked active.
struct DashboardMultiAccountSnapshotTests {
    @Test
    func `multiple payloads for one provider collapse into a single row with accounts`() throws {
        let snapshot = self.snapshot(
            payloads: [
                self.payload(email: "first@example.com", accountKey: "claude:first", usedPercent: 10),
                self.payload(email: "second@example.com", accountKey: "claude:second", usedPercent: 40),
            ],
            activeAccountKeys: [:])
        let object = try self.jsonObject(snapshot)
        let providers = try #require(object["providers"] as? [[String: Any]])

        #expect(providers.count == 1)
        let accounts = try #require(providers[0]["accounts"] as? [[String: Any]])
        #expect(accounts.compactMap { $0["label"] as? String } == ["first@example.com", "second@example.com"])
        #expect(accounts.compactMap { $0["id"] as? String } == ["claude:first", "claude:second"])
        #expect(accounts.compactMap { $0["active"] as? Bool } == [true, false])
    }

    @Test
    func `provider row and active flag follow the serving account selection`() throws {
        let snapshot = self.snapshot(
            payloads: [
                self.payload(email: "first@example.com", accountKey: "claude:first", usedPercent: 10),
                self.payload(email: "second@example.com", accountKey: "claude:second", usedPercent: 40),
            ],
            activeAccountKeys: ["claude": "claude:second"])
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let identity = try #require(provider["identity"] as? [String: Any])
        let accounts = try #require(provider["accounts"] as? [[String: Any]])

        #expect(identity["accountEmail"] as? String == "second@example.com")
        #expect(accounts.compactMap { $0["active"] as? Bool } == [false, true])
        let windows = try #require(provider["windows"] as? [[String: Any]])
        #expect(windows.first?["usedPercent"] as? Double == 40)
    }

    @Test
    func `single account provider keeps its row-only shape`() throws {
        let snapshot = self.snapshot(
            payloads: [self.payload(email: "only@example.com", accountKey: "claude:only", usedPercent: 10)],
            activeAccountKeys: [:])
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)

        #expect(provider["accounts"] == nil)
    }

    @Test
    func `accounts fall back to positional labels without identity`() throws {
        let snapshot = self.snapshot(
            payloads: [
                self.payload(email: nil, accountKey: "codex:a", usedPercent: 10, provider: .codex),
                self.payload(email: nil, accountKey: "codex:b", usedPercent: 20, provider: .codex),
            ],
            activeAccountKeys: [:],
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)]))
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let accounts = try #require(provider["accounts"] as? [[String: Any]])

        #expect(accounts.compactMap { $0["label"] as? String } == ["Account 1", "Account 2"])
    }

    @Test
    func `claude swap keeps ownership of the Claude account list`() throws {
        let claudeSwapAccounts = ClaudeSwapAccountProjection.accountSnapshots(from: ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [ClaudeSwapAccountRow(
                number: 1,
                email: "swap@example.com",
                isActive: true,
                usageStatus: .ok,
                fiveHour: nil,
                sevenDay: nil)]))
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [
                self.payload(email: "first@example.com", accountKey: "claude:first", usedPercent: 10),
                self.payload(email: "second@example.com", accountKey: "claude:second", usedPercent: 40),
            ],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)]),
            identityMode: .full,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil,
            activeAccountKeys: [:],
            claudeSwap: DashboardClaudeSwapInput(
                accounts: claudeSwapAccounts,
                adapterError: nil,
                weeklyWorkDays: nil))
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let accounts = try #require(provider["accounts"] as? [[String: Any]])

        #expect(accounts.compactMap { $0["label"] as? String } == ["swap@example.com"])
    }

    private func snapshot(
        payloads: [ProviderPayload],
        activeAccountKeys: [String: String],
        config: CodexBarConfig = CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)]))
        -> DashboardSnapshotPayload
    {
        DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: payloads,
            costPayloads: [],
            config: config,
            identityMode: .full,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil,
            activeAccountKeys: activeAccountKeys)
    }

    private func payload(
        email: String?,
        accountKey: String,
        usedPercent: Double,
        provider: UsageProvider = .claude) -> ProviderPayload
    {
        let identity = email.map { email in
            ProviderIdentitySnapshot(
                providerID: provider.instanceID,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: nil)
        }
        return ProviderPayload(
            provider: provider,
            account: nil,
            cacheAccountKey: accountKey,
            version: nil,
            source: "auto",
            status: nil,
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: Date(timeIntervalSince1970: 0),
                identity: identity),
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
    }

    private func jsonObject(_ payload: some Encodable) throws -> [String: Any] {
        let json = try #require(CodexBarCLI.encodeJSON(payload, pretty: false))
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
