import CodexBarCore
import Foundation

extension SettingsStore {
    var remoteCodexBarServerURL: String {
        get { self.remoteCodexBarServerURLStorage }
        set {
            // A token is scoped to the configured server. Never retain it across an endpoint edit,
            // where an observation callback could otherwise send the old server's token to the new host.
            self.applyRemoteCodexBarConfiguration(serverURL: newValue, bearerToken: "")
        }
    }

    var remoteCodexBarBearerToken: String {
        get { self.remoteCodexBarBearerTokenStorage }
        set {
            self.remoteCodexBarBearerTokenStorage = newValue
            self.remoteCodexBarTokenLoadNeedsRetry = false
            do {
                try self.remoteCodexBarTokenStore.storeToken(newValue)
                self.remoteCodexBarSecretError = nil
            } catch {
                self.remoteCodexBarSecretError = error.localizedDescription
            }
            self.remoteCodexBarConfigurationRevision &+= 1
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    func applyRemoteCodexBarConfiguration(serverURL: String, bearerToken: String) {
        let normalizedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)

        // These storage properties are deliberately not part of menu observation. Publishing one
        // revision after both values change makes the endpoint/token pair atomic to refresh consumers.
        self.remoteCodexBarServerURLStorage = normalizedURL
        self.remoteCodexBarBearerTokenStorage = normalizedToken
        self.userDefaults.set(normalizedURL, forKey: "remoteCodexBarServerURL")
        self.remoteCodexBarTokenLoadNeedsRetry = false
        do {
            try self.remoteCodexBarTokenStore.storeToken(normalizedToken)
            self.remoteCodexBarSecretError = nil
        } catch {
            self.remoteCodexBarSecretError = error.localizedDescription
        }
        self.remoteCodexBarConfigurationRevision &+= 1
        self.noteBackgroundWorkSettingsChanged()
    }

    func retryRemoteCodexBarTokenLoadIfNeeded() {
        guard self.remoteCodexBarTokenLoadNeedsRetry else { return }
        do {
            self.remoteCodexBarBearerTokenStorage = try self.remoteCodexBarTokenStore.loadToken() ?? ""
            self.remoteCodexBarSecretError = nil
            self.remoteCodexBarTokenLoadNeedsRetry = false
        } catch {
            self.remoteCodexBarSecretError = error.localizedDescription
            self.remoteCodexBarTokenLoadNeedsRetry =
                error as? RemoteCodexBarTokenStoreError == .temporarilyUnavailable
        }
    }

    var remoteCodexBarConfiguration: RemoteCodexBarConfiguration? {
        RemoteCodexBarConfiguration.resolve(
            serverURL: self.remoteCodexBarServerURL,
            bearerToken: self.remoteCodexBarBearerToken)
    }

    func remoteCodexBarURLValidationMessage(for serverURL: String) -> String? {
        let raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard ProviderEndpointOverrideValidator().validatedURLAllowingPrivateNetworkHTTP(raw) != nil else {
            return "Use HTTPS, or HTTP only for loopback/private-network hosts. User info is not allowed."
        }
        guard URLComponents(string: raw)?.query == nil, URLComponents(string: raw)?.fragment == nil else {
            return "The server URL cannot include a query or fragment."
        }
        return nil
    }
}
