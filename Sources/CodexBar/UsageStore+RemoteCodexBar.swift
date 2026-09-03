import Foundation

extension UsageStore {
    func scheduleRemoteCodexBarRefresh() {
        self.settings.retryRemoteCodexBarTokenLoadIfNeeded()
        guard let configuration = self.settings.remoteCodexBarConfiguration else {
            self.remoteCodexBarRefreshTask?.cancel()
            self.remoteCodexBarRefreshTask = nil
            self.remoteCodexBarRefreshTaskConfigurationID = nil
            self.clearRemoteCodexBarState()
            return
        }

        let configurationID = configuration.configurationID
        guard self.remoteCodexBarRefreshTask == nil ||
            self.remoteCodexBarRefreshTaskConfigurationID != configurationID
        else { return }

        self.remoteCodexBarRefreshTask?.cancel()
        self.prepareRemoteCodexBarRefresh(configurationID: configurationID)
        self.remoteCodexBarRefreshTaskConfigurationID = configurationID
        self.remoteCodexBarRefreshInFlight = true
        self.remoteCodexBarRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRemoteCodexBarRefresh(
                configuration: configuration,
                configurationID: configurationID)
            guard self.remoteCodexBarRefreshTaskConfigurationID == configurationID else { return }
            self.remoteCodexBarRefreshTask = nil
            self.remoteCodexBarRefreshTaskConfigurationID = nil
            self.remoteCodexBarRefreshInFlight = false
        }
    }

    func refreshRemoteCodexBarSnapshot() async {
        self.settings.retryRemoteCodexBarTokenLoadIfNeeded()
        guard let configuration = self.settings.remoteCodexBarConfiguration else {
            self.clearRemoteCodexBarState()
            return
        }

        let configurationID = configuration.configurationID
        self.prepareRemoteCodexBarRefresh(configurationID: configurationID)
        self.remoteCodexBarRefreshInFlight = true
        defer { self.remoteCodexBarRefreshInFlight = false }
        await self.performRemoteCodexBarRefresh(
            configuration: configuration,
            configurationID: configurationID)
    }

    private func performRemoteCodexBarRefresh(
        configuration: RemoteCodexBarConfiguration,
        configurationID: String) async
    {
        do {
            let snapshot = try await self.remoteCodexBarClient.fetch(configuration: configuration)
            guard !Task.isCancelled,
                  self.settings.remoteCodexBarConfiguration?.configurationID == configurationID
            else { return }
            let projection = RemoteCodexBarProjection.make(
                snapshot: snapshot,
                serverURL: configuration.snapshotURL)
            self.remoteCodexBarSnapshots = projection.snapshots
            self.remoteCodexBarProviderIDs = projection.providerIDs
            self.remoteCodexBarPrimarySnapshots = projection.primarySnapshots
            self.remoteCodexBarError = nil
        } catch is CancellationError {
            return
        } catch {
            guard self.settings.remoteCodexBarConfiguration?.configurationID == configurationID else { return }
            if let snapshotError = error as? RemoteCodexBarSnapshotError,
               !snapshotError.preservesLastGoodSnapshot
            {
                self.remoteCodexBarSnapshots = []
                self.remoteCodexBarProviderIDs = []
                self.remoteCodexBarPrimarySnapshots = [:]
            }
            // Preserve the last successful cards only for a transient failure of this exact configuration.
            self.remoteCodexBarError = error.localizedDescription
        }
    }

    private func prepareRemoteCodexBarRefresh(configurationID: String) {
        if let previousConfigurationID = self.remoteCodexBarSnapshotConfigurationID,
           previousConfigurationID != configurationID
        {
            self.remoteCodexBarSnapshots = []
            self.remoteCodexBarProviderIDs = []
            self.remoteCodexBarPrimarySnapshots = [:]
        }
        self.remoteCodexBarSnapshotConfigurationID = configurationID
    }

    private func clearRemoteCodexBarState() {
        self.remoteCodexBarSnapshots = []
        self.remoteCodexBarProviderIDs = []
        self.remoteCodexBarPrimarySnapshots = [:]
        self.remoteCodexBarError = nil
        self.remoteCodexBarRefreshInFlight = false
        self.remoteCodexBarSnapshotConfigurationID = nil
    }
}
