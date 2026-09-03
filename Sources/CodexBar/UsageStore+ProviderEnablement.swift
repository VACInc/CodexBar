import CodexBarCore
import Foundation

extension UsageStore {
    func enabledProviders() -> [ProviderInstanceID] {
        if self.settings.usesRemoteCodexBarProvidersOnly {
            return self.remoteCodexBarProviderIDs
        }
        // Use cached enablement to avoid repeated UserDefaults lookups in animation ticks.
        let enabled = self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata)
        let now = Date()
        return enabled.filter { self.isEnabledProviderInstance($0, now: now) }
    }

    /// Enabled providers without availability filtering. Used for display (switcher, merge-icons).
    func enabledProvidersForDisplay() -> [ProviderInstanceID] {
        if self.settings.usesRemoteCodexBarProvidersOnly {
            return self.remoteCodexBarProviderIDs
        }
        return self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata)
    }

    /// Providers that should actually participate in background refresh/status/token work.
    func enabledProvidersForBackgroundWork() -> [ProviderInstanceID] {
        if self.settings.usesRemoteCodexBarProvidersOnly {
            return []
        }
        return self.enabledProviders()
    }

    func snapshot(for instanceID: ProviderInstanceID) -> UsageSnapshot? {
        if self.settings.usesRemoteCodexBarProvidersOnly {
            return self.remoteCodexBarPrimarySnapshots[instanceID]
        }
        return self.snapshots[instanceID]
    }
}
