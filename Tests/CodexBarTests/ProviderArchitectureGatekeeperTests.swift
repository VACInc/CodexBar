import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore
@testable import CodexBarWidget

@MainActor
struct ProviderArchitectureGatekeeperTests {
    @Test
    func `every provider has descriptor and implementation manifest entries`() {
        let expected = Set(UsageProvider.allCases)
        let descriptors = Set(ProviderDescriptorRegistry.all.map(\.id))
        let implementations = Set(ProviderImplementationRegistry.all.map(\.id))
        let missingDescriptors = expected.subtracting(descriptors).map(\.rawValue).sorted()
        let missingImplementations = expected.subtracting(implementations).map(\.rawValue).sorted()

        #expect(
            missingDescriptors.isEmpty,
            "Missing descriptor manifest entries: \(missingDescriptors.joined(separator: ", "))")
        #expect(
            missingImplementations.isEmpty,
            "Missing implementation manifest entries: \(missingImplementations.joined(separator: ", "))")
    }

    @Test
    func `credential adapters self report capabilities through descriptors`() {
        for descriptor in ProviderDescriptorRegistry.all {
            guard let adapter = descriptor.credentials else { continue }

            #expect(
                ProviderConfigEnvironment.supportsAPIKeyOverride(for: descriptor.id) ==
                    adapter.supportsAPIKeyOverride,
                "API-key capability drifted for \(descriptor.id.rawValue).")
            #expect(
                (TokenAccountSupportCatalog.support(for: descriptor.id) != nil) ==
                    (adapter.tokenAccountSupport != nil),
                "Token-account capability drifted for \(descriptor.id.rawValue).")
        }
    }

    @Test
    func `every provider can produce and read its registered settings section`() {
        let settings = testSettingsStore(suiteName: "ProviderArchitectureGatekeeperTests-settings-sections")
        let context = ProviderSettingsSnapshotContext(settings: settings, tokenOverride: nil)
        var builder = ProviderSettingsSnapshotBuilder()

        for implementation in ProviderImplementationRegistry.all {
            let providerName = implementation.id.rawValue
            let registration = ProviderDescriptorRegistry.descriptor(for: implementation.id).settingsSection
            guard let contribution = implementation.settingsSnapshot(context: context) else {
                Issue.record("Missing settings-section contribution for provider '\(providerName)'.")
                continue
            }
            #expect(
                registration.accepts(contribution),
                "Settings-section registration does not match provider '\(providerName)'.")
            builder.apply(contribution)
        }

        let snapshot = builder.build()
        for descriptor in ProviderDescriptorRegistry.all {
            #expect(
                descriptor.settingsSection.canRead(from: snapshot),
                "Could not read settings section for provider '\(descriptor.id.rawValue)'.")
        }
    }

    @Test
    func `empty settings snapshot factory has no provider sections`() {
        let snapshot = ProviderSettingsSnapshot.make()

        #expect(snapshot.abacus == nil)
        #expect(!snapshot.debugMenuEnabled)
        #expect(!snapshot.debugKeepCLISessionsAlive)
    }

    @Test
    func `every provider descriptor has a loadable SVG resource`() throws {
        let resources = try Self.repoRoot()
            .appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)

        for descriptor in ProviderDescriptorRegistry.all {
            let resourceName = descriptor.branding.iconResourceName
            let url = resources.appending(path: "\(resourceName).svg")
            #expect(
                FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
                "Missing SVG for \(descriptor.id.rawValue): \(resourceName).svg")
            #expect(NSImage(contentsOf: url) != nil, "Could not load \(resourceName).svg as NSImage")
        }
    }

    @Test
    func `widget provider choices match selectable descriptor metadata`() {
        let selectable = Set(ProviderDescriptorRegistry.all.filter(\.metadata.widgetSelectable).map(\.id))
        let choices = Set(ProviderChoice.allCases.map(\.provider))
        let missing = selectable.subtracting(choices).map(\.rawValue).sorted()
        let unexpected = choices.subtracting(selectable).map(\.rawValue).sorted()

        #expect(
            missing.isEmpty,
            "Missing ProviderChoice cases for widget-selectable providers: \(missing.joined(separator: ", "))")
        #expect(
            unexpected.isEmpty,
            "ProviderChoice cases marked non-selectable in descriptor metadata: \(unexpected.joined(separator: ", "))")
    }

    @Test
    func `widget short labels preserve compact provider names`() {
        let overrides: [UsageProvider: String] = [
            .antigravity: "Anti",
            .alibabatokenplan: "Token Plan",
            .vertexai: "Vertex",
            .perplexity: "Pplx",
            .mimo: "MiMo",
            .sakana: "Sakana",
            .abacus: "Abacus",
            .bedrock: "Bedrock",
            .jetbrains: "JetBrains",
            .moonshot: "Moonshot",
        ]
        for descriptor in ProviderDescriptorRegistry.all {
            let expected = overrides[descriptor.id] ?? descriptor.metadata.displayName
            #expect(
                descriptor.metadata.shortDisplayName == expected,
                "Unexpected widget short label for \(descriptor.id.rawValue).")
        }
    }

    @Test
    func `descriptor widget colors preserve the pre-derivation literals`() {
        var widgetFingerprint: UInt64 = 1_469_598_103_934_665_603
        var burnDownFingerprint = widgetFingerprint
        for descriptor in ProviderDescriptorRegistry.all {
            Self.hash(descriptor.id.rawValue.utf8, into: &widgetFingerprint)
            Self.hash(descriptor.branding.widgetColor, into: &widgetFingerprint)
            Self.hash(descriptor.id.rawValue.utf8, into: &burnDownFingerprint)
            Self.hash(descriptor.branding.burnDownWidgetColor, into: &burnDownFingerprint)
        }

        #expect(widgetFingerprint == 2_606_598_074_008_460_152)
        #expect(burnDownFingerprint == 2_519_601_461_320_236_490)
    }

    @Test
    func `descriptor unavailable debug messages preserve the legacy table`() throws {
        let descriptors = ProviderDescriptorRegistry.all.filter { $0.metadata.debugLogUnavailableMessage != nil }
        var fingerprint: UInt64 = 1_469_598_103_934_665_603
        for descriptor in descriptors {
            Self.hash(descriptor.id.rawValue.utf8, into: &fingerprint)
            try Self.hash(#require(descriptor.metadata.debugLogUnavailableMessage?.utf8), into: &fingerprint)
        }

        #expect(descriptors.count == 38)
        #expect(fingerprint == 2_208_147_801_202_684_136)
    }

    @Test
    func `debug pane provider curation preserves legacy membership and order`() {
        let descriptors = ProviderDescriptorRegistry.all
        let ordered: ((ProviderDebugPaneCapabilities) -> Int?) -> [UsageProvider] = { rank in
            descriptors.compactMap { descriptor -> (UsageProvider, Int)? in
                guard let value = rank(descriptor.metadata.debugPane) else { return nil }
                return (descriptor.id, value)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        }

        #expect(ordered { $0.probeLogOrder } == [.codex, .claude, .cursor, .augment, .amp, .ollama])
        #expect(ordered { $0.notificationSimulationOrder } == [.codex, .claude])
        #expect(ordered { $0.errorSimulationOrder } == [
            .codex, .claude, .gemini, .antigravity, .augment, .amp, .t3chat, .zoommate, .ollama,
        ])
    }

    @Test
    func `small provider capabilities preserve legacy registries`() {
        let descriptors = ProviderDescriptorRegistry.all
        #expect(Set(descriptors.filter(\.metadata.balanceOnly).map(\.id)) == [
            .deepseek, .deepinfra, .mistral, .moonshot, .poe,
        ])
        #expect(Set(descriptors.filter(\.metadata.usesDetailBackedWindow).map(\.id)) == [
            .warp, .kilo, .mistral, .deepseek, .deepinfra, .qoder, .crof, .chutes,
        ])
        #if os(macOS)
        #expect(Set(descriptors.filter(\.tokenCost.supportsTokenSnapshot).map(\.id)) == [
            .codex, .claude, .cursor, .vertexai, .bedrock,
        ])
        #else
        #expect(Set(descriptors.filter(\.tokenCost.supportsTokenSnapshot).map(\.id)) == [
            .codex, .claude, .vertexai, .bedrock,
        ])
        #endif
        #expect(Set(descriptors.filter { $0.cli.binaryLocator != nil }.map(\.id)) == [
            .codex, .claude, .gemini,
        ])

        #expect(CodexProviderDescriptor.descriptor.tokenCost.menuHintLines == [.localized("codex_api_estimate_hint")])
        #expect(ClaudeProviderDescriptor.descriptor.tokenCost.menuHintLines == [.estimate])
        #expect(CursorProviderDescriptor.descriptor.tokenCost.menuHintLines == [.estimate])
        #expect(VertexAIProviderDescriptor.descriptor.tokenCost.menuHintLines == [.localized("cost_estimate_hint")])
        #expect(BedrockProviderDescriptor.descriptor.tokenCost.menuHintLines == [
            .literal("AWS Cost Explorer billing can lag."),
        ])
        #expect(OpenAIAPIProviderDescriptor.descriptor.tokenCost.menuHintLines == [
            .literal("Reported by OpenAI Admin API organization usage."),
        ])
        #expect(MistralProviderDescriptor.descriptor.tokenCost.menuHintLines == [
            .literal("Reported by Mistral billing usage."),
        ])
    }

    @Test
    func `cross provider case clusters are derived or specifically justified`() throws {
        let root = try Self.repoRoot()
        let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
        let providerCases = UsageProvider.allCases.map(\.rawValue)
        let enumerator = try #require(FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]))
        var failures: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !relativePath.contains("/Providers/") else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            let hitLines = lines.indices.filter { index in
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { return false }
                return providerCases.contains { Self.containsProviderCase($0, in: lines[index]) }
            }
            guard !hitLines.isEmpty else { continue }

            if Self.auditedCrossProviderFiles.contains(relativePath) {
                for cluster in Self.providerCaseClusters(hitLines) {
                    let markerStart = max(0, cluster.lowerBound - Self.providerCaseMarkerWindow)
                    let hasMarker = lines[markerStart...cluster.lowerBound]
                        .contains { $0.contains("Provider-specific by design:") }
                    if !hasMarker {
                        failures.append(
                            "\(relativePath):\(cluster.lowerBound + 1) has an unjustified provider case cluster; " +
                                "derive it or add '// Provider-specific by design: <specific reason>' immediately " +
                                "before the cluster.")
                    }
                }
                continue
            }

            let isProviderOwnedFile = Self.providerOwnedFilenameTokens.contains { token in
                url.deletingPathExtension().lastPathComponent.contains(token)
            }
            let isAllowlisted = Self.genericDispatchAllowlist.contains(relativePath)
            let hasExistingJustification = source.contains("Provider-specific by design:")
            if !isProviderOwnedFile, !isAllowlisted, !hasExistingJustification {
                failures.append(
                    "\(relativePath):\(hitLines[0] + 1) is a new cross-provider case-dispatch file; " +
                        "add it to the audited inventory, derive the dispatch, or justify the provider owner.")
            }
        }

        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    private static let providerCaseMarkerWindow = 120
    private static let providerCaseClusterGap = 120

    private static let auditedCrossProviderFiles: Set<String> = [
        "Sources/CodexBar/Config/CodexBarConfigMigrator.swift",
        "Sources/CodexBar/PreferencesProviderDetailView.swift",
        "Sources/CodexBar/PreferencesProvidersPane.swift",
        "Sources/CodexBar/SessionQuotaNotifications.swift",
        "Sources/CodexBar/SettingsStore+ProviderDetection.swift",
        "Sources/CodexBar/SettingsStore+TokenAccounts.swift",
        "Sources/CodexBar/SettingsStore+TokenCost.swift",
        "Sources/CodexBar/StatusItemController+AccountMenuDisplay.swift",
        "Sources/CodexBar/StatusItemController+Actions.swift",
        "Sources/CodexBar/StatusItemController+Animation.swift",
        "Sources/CodexBar/StatusItemController+Menu.swift",
        "Sources/CodexBar/StatusItemController+MenuCardModel.swift",
        "Sources/CodexBar/StatusItemController+MenuTracking.swift",
        "Sources/CodexBar/UsageStore+Accessors.swift",
        "Sources/CodexBar/UsageStore+BackgroundRefresh.swift",
        "Sources/CodexBar/UsageStore+HighestUsage.swift",
        "Sources/CodexBar/UsageStore+HistoricalPace.swift",
        "Sources/CodexBar/UsageStore+OpenAIWeb.swift",
        "Sources/CodexBar/UsageStore+PlanUtilization.swift",
        "Sources/CodexBar/UsageStore+QuotaWarnings.swift",
        "Sources/CodexBar/UsageStore+Refresh.swift",
        "Sources/CodexBar/UsageStore+SessionEquivalents.swift",
        "Sources/CodexBar/UsageStore+SessionQuotaTransition.swift",
        "Sources/CodexBar/UsageStore+TokenAccounts.swift",
        "Sources/CodexBar/UsageStore+TokenCost.swift",
        "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
        "Sources/CodexBar/UsageStore.swift",
        "Sources/CodexBarCLI/CLICardsCommand.swift",
        "Sources/CodexBarCLI/CLICardsRenderer.swift",
        "Sources/CodexBarCLI/CLIClaudeSwapCards.swift",
        "Sources/CodexBarCLI/CLIConfigCommand.swift",
        "Sources/CodexBarCLI/CLICostCommand.swift",
        "Sources/CodexBarCLI/CLIHelpers.swift",
        "Sources/CodexBarCLI/CLISessionsCommand.swift",
        "Sources/CodexBarCLI/DashboardSnapshotBuilder.swift",
        "Sources/CodexBarCore/CostUsageFetcher.swift",
        "Sources/CodexBarCore/PiSessionCostScanner.swift",
        "Sources/CodexBarCore/ProviderStorageFootprint.swift",
        "Sources/CodexBarCore/UsageFetcher.swift",
        "Sources/CodexBarCore/UsageFormatter.swift",
        "Sources/CodexBarCore/Vendored/CostUsage/CostUsageCache.swift",
        "Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner.swift",
        "Sources/CodexBarWidget/BurnDownWidgetProvider.swift",
        "Sources/CodexBarWidget/CodexBarWidgetViews.swift",
    ]

    private static let genericDispatchAllowlist: Set<String> = [
        "Sources/CodexBar/CostHistoryChartMenuView.swift",
        "Sources/CodexBar/HistoricalUsagePace.swift",
        "Sources/CodexBar/IconRenderer.swift",
        "Sources/CodexBar/InlineUsageDashboardContent.swift",
        "Sources/CodexBar/MenuBarLayout.swift",
        "Sources/CodexBar/MenuBarLayoutEditor.swift",
        "Sources/CodexBar/MenuBarMetricWindowResolver.swift",
        "Sources/CodexBar/MenuCardView+Costs.swift",
        "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
        "Sources/CodexBar/MenuCardView.swift",
        "Sources/CodexBar/MenuDescriptor.swift",
        "Sources/CodexBar/MenuOpenRefreshPlan.swift",
        "Sources/CodexBar/PredictivePaceWarnings.swift",
        "Sources/CodexBar/PreferencesMenuPane.swift",
        "Sources/CodexBar/PreferencesSpendDashboardPane.swift",
        "Sources/CodexBar/ProviderRegistry.swift",
        "Sources/CodexBar/PreferencesProvidersPane+Testing.swift",
        "Sources/CodexBar/SettingsStore+MenuObservation.swift",
        "Sources/CodexBar/SettingsStore+MenuPreferences.swift",
        "Sources/CodexBar/SettingsStore.swift",
        "Sources/CodexBar/ShareStatsPayload.swift",
        "Sources/CodexBar/SpendDashboardController.swift",
        "Sources/CodexBar/SpendDashboardModel+ModelBreakdown.swift",
        "Sources/CodexBar/SpendDashboardModel.swift",
        "Sources/CodexBar/StatusItemController+CompactAccountMenu.swift",
        "Sources/CodexBar/StatusItemController+CostMenuCard.swift",
        "Sources/CodexBar/StatusItemController+CountdownRefresh.swift",
        "Sources/CodexBar/StatusItemController+HostedSubmenus.swift",
        "Sources/CodexBar/StatusItemController+MemoryPressure.swift",
        "Sources/CodexBar/StatusItemController+MenuBarLayout.swift",
        "Sources/CodexBar/StatusItemController+MenuSwitcherWarmup.swift",
        "Sources/CodexBar/StatusItemController+MenuTypes.swift",
        "Sources/CodexBar/StatusItemController+MenuViewportRestore.swift",
        "Sources/CodexBar/StatusItemController+OverviewSubmenus.swift",
        "Sources/CodexBar/StatusItemController+ProviderNavigation.swift",
        "Sources/CodexBar/StatusItemController+SwitcherMetrics.swift",
        "Sources/CodexBar/StatusItemController.swift",
        "Sources/CodexBar/UsageStore+APIKeyDebug.swift",
        "Sources/CodexBar/UsageStore+LimitResetCelebration.swift",
        "Sources/CodexBar/UsageStore+LimitResetIdentity.swift",
        "Sources/CodexBar/UsageStore+ProviderStorage.swift",
        "Sources/CodexBar/UsageStore+RefreshEnrichment.swift",
        "Sources/CodexBar/UsageStore+TokenAccountLabels.swift",
        "Sources/CodexBarCore/AgentSession.swift",
        "Sources/CodexBarCore/LocalAgentSessionScanner.swift",
        "Sources/CodexBarCore/Logging/LogCategories.swift",
        "Sources/CodexBarCore/PathEnvironment.swift",
        "Sources/CodexBarCore/ProviderEndpointOverrideValidator.swift",
        "Sources/CodexBarCore/SessionWindowFocuser.swift",
        "Sources/CodexBarCore/UsageSnapshot+SwitcherWeeklyWindow.swift",
        "Sources/CodexBarCore/Vendored/CostUsage/ModelsDevPricing.swift",
        "Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift",
        "Sources/CodexBarCLI/CLIHelp.swift",
    ]

    private static let providerOwnedFilenameTokens = [
        "Codex", "Claude", "Cursor", "Gemini", "Antigravity", "Copilot", "Zai", "MiniMax", "Kimi", "Kilo",
        "Kiro", "Vertex", "Augment", "Moonshot", "Amp", "Synthetic", "OpenRouter", "ElevenLabs", "Warp",
        "Windsurf", "Perplexity", "Mimo", "Doubao", "Sakana", "Abacus", "Mistral", "DeepSeek", "DeepInfra",
        "Crof", "Venice", "CommandCode", "Qoder", "Bedrock", "Grok", "Groq", "Deepgram", "Poe",
        "ClawRouter", "Sub2API", "OpenAI", "Alibaba", "StepFun", "Wayfinder", "ZoomMate", "Notion",
    ]

    private static func providerCaseClusters(_ hitLines: [Int]) -> [ClosedRange<Int>] {
        guard let first = hitLines.first else { return [] }
        var clusters: [ClosedRange<Int>] = []
        var start = first
        var end = first
        for line in hitLines.dropFirst() {
            if line - end > self.providerCaseClusterGap {
                clusters.append(start...end)
                start = line
            }
            end = line
        }
        clusters.append(start...end)
        return clusters
    }

    private static func containsProviderCase(_ rawValue: String, in line: String) -> Bool {
        let needle = ".\(rawValue)"
        var searchStart = line.startIndex
        while let range = line.range(of: needle, range: searchStart..<line.endIndex) {
            if range.upperBound == line.endIndex || !Self.isIdentifierCharacter(line[range.upperBound]) {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path(percentEncoded: false))
            {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func hash(_ color: ProviderColor, into fingerprint: inout UInt64) {
        for component in [color.red, color.green, color.blue] {
            var bits = component.bitPattern
            for _ in 0..<MemoryLayout<UInt64>.size {
                fingerprint = (fingerprint ^ UInt64(UInt8(truncatingIfNeeded: bits))) &* 1_099_511_628_211
                bits >>= 8
            }
        }
    }

    private static func hash(_ bytes: String.UTF8View, into fingerprint: inout UInt64) {
        for byte in bytes {
            fingerprint = (fingerprint ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
