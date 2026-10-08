import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// The served snapshot has no cadence field, but Antigravity's descriptor picks its session/weekly lanes,
/// switcher indicator, and pace by `windowMinutes`. Remote quota-summary lanes must carry the cadence their
/// kind encodes, or a remote Antigravity card loses its semantic windows.
struct RemoteCodexBarAntigravityWindowTests {
    @Test
    func `antigravity quota summary kinds map to their cadence`() {
        #expect(RemoteCodexBarProjection.windowMinutes(forKind: "antigravity-quota-summary-gemini-5h") == 300)
        #expect(RemoteCodexBarProjection.windowMinutes(forKind: "antigravity-quota-summary-3p-weekly") == 10080)
        #expect(RemoteCodexBarProjection.windowMinutes(forKind: "antigravity-quota-summary-gemini-pro") == nil)
        #expect(RemoteCodexBarProjection.windowMinutes(forKind: "weekly") == nil)
        #expect(RemoteCodexBarProjection.windowMinutes(forKind: "claude-weekly-scoped-fable") == nil)
    }

    @Test
    func `remote antigravity card resolves session and weekly windows`() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(RemoteCodexBarSnapshot.self, from: Data(Self.antigravityJSON.utf8))
        let serverURL = try #require(URL(string: "http://mini.example:8484/dashboard/v1/snapshot"))

        let projection = RemoteCodexBarProjection.make(snapshot: snapshot, serverURL: serverURL)
        let usage = try #require(projection.primarySnapshots[.antigravity])
        let extras = try #require(usage.extraRateWindows)
        let minutes = Dictionary(uniqueKeysWithValues: extras.map { ($0.id, $0.window.windowMinutes) })
        #expect(minutes["antigravity-quota-summary-gemini-5h"] == 300)
        #expect(minutes["antigravity-quota-summary-gemini-weekly"] == 10080)
        #expect(minutes["antigravity-quota-summary-3p-5h"] == 300)
        #expect(minutes["antigravity-quota-summary-3p-weekly"] == 10080)

        let semantic = AntigravityProviderDescriptor.descriptor.presentation.semanticWindows(snapshot: usage)
        #expect(semantic.session?.usedPercent == 40)
        #expect(semantic.weekly?.usedPercent == 25)
    }

    private static let antigravityJSON = """
    {
      "schemaVersion": 1,
      "generatedAt": "2026-10-07T12:00:00Z",
      "staleAfterSeconds": 180,
      "host": {"codexBarVersion": "0.73.0", "refreshIntervalSeconds": 60, "usageBarsShowUsed": false},
      "providers": [
        {
          "id": "antigravity",
          "name": "Antigravity",
          "enabled": true,
          "display": {"accentColor": "#60BA7E", "sortKey": 50, "priority": "normal"},
          "source": "cli",
          "status": null,
          "identity": null,
          "windows": [
            {"kind": "antigravity-quota-summary-gemini-5h", "label": "Gemini 5-hour", "usedPercent": 40,
             "remainingPercent": 60, "resetAt": "2026-10-07T15:00:00Z"},
            {"kind": "antigravity-quota-summary-gemini-weekly", "label": "Gemini weekly", "usedPercent": 25,
             "remainingPercent": 75, "resetAt": "2026-10-14T12:00:00Z"},
            {"kind": "antigravity-quota-summary-3p-5h", "label": "Claude/GPT 5-hour", "usedPercent": 10,
             "remainingPercent": 90, "resetAt": null},
            {"kind": "antigravity-quota-summary-3p-weekly", "label": "Claude/GPT weekly", "usedPercent": 5,
             "remainingPercent": 95, "resetAt": null}
          ],
          "credits": null,
          "cost": null,
          "error": null,
          "updatedAt": "2026-10-07T11:59:00Z"
        }
      ]
    }
    """
}
