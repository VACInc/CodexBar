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
            let normalizedToken = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let credential = self.remoteCodexBarStoredCredential(
                serverURL: self.remoteCodexBarServerURLStorage,
                bearerToken: normalizedToken,
                allowsPlainHTTP: self.remoteCodexBarAllowsPlainHTTPStorage)
            guard normalizedToken.isEmpty || credential != nil else {
                self.remoteCodexBarSecretError = "Save a valid server URL before saving its bearer token."
                return
            }
            do {
                try self.remoteCodexBarTokenStore.storeCredential(credential)
                self.remoteCodexBarBearerTokenStorage = normalizedToken
                self.remoteCodexBarTokenLoadNeedsRetry = false
                self.remoteCodexBarSecretError = nil
            } catch {
                self.remoteCodexBarSecretError = error.localizedDescription
                return
            }
            self.remoteCodexBarConfigurationRevision &+= 1
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var remoteCodexBarAllowsPlainHTTP: Bool {
        self.remoteCodexBarAllowsPlainHTTPStorage
    }

    @discardableResult
    func applyRemoteCodexBarConfiguration(
        serverURL: String,
        bearerToken: String,
        allowsPlainHTTP: Bool = false) -> Bool
    {
        let normalizedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresPlainHTTPConsent = RemoteCodexBarConfiguration.requiresPlainHTTPConsent(serverURL: normalizedURL)
        guard !requiresPlainHTTPConsent || allowsPlainHTTP else {
            self.remoteCodexBarSecretError =
                "Confirm that the bearer token may be sent over unencrypted private-network HTTP."
            return false
        }
        let storesPlainHTTPConsent = requiresPlainHTTPConsent && allowsPlainHTTP
        let credential = self.remoteCodexBarStoredCredential(
            serverURL: normalizedURL,
            bearerToken: normalizedToken,
            allowsPlainHTTP: storesPlainHTTPConsent)
        guard normalizedToken.isEmpty || credential != nil else {
            self.remoteCodexBarSecretError = "Save a valid server URL and bearer token together."
            return false
        }

        // The Keychain record binds the endpoint and token in one durable write. UserDefaults keeps only
        // a display draft, so an interruption can never recombine authority from two different servers.
        do {
            try self.remoteCodexBarTokenStore.storeCredential(credential)
        } catch {
            self.remoteCodexBarSecretError = error.localizedDescription
            return false
        }

        // These storage properties are deliberately not part of menu observation. Publishing one
        // revision after both values change makes the endpoint/token pair atomic to refresh consumers.
        self.remoteCodexBarServerURLStorage = normalizedURL
        self.remoteCodexBarBearerTokenStorage = normalizedToken
        self.remoteCodexBarAllowsPlainHTTPStorage = storesPlainHTTPConsent
        self.userDefaults.set(normalizedURL, forKey: "remoteCodexBarServerURL")
        self.remoteCodexBarTokenLoadNeedsRetry = false
        self.remoteCodexBarSecretError = nil
        self.remoteCodexBarConfigurationRevision &+= 1
        self.noteBackgroundWorkSettingsChanged()
        return true
    }

    func retryRemoteCodexBarTokenLoadIfNeeded() {
        guard self.remoteCodexBarTokenLoadNeedsRetry else { return }
        guard !KeychainAccessGate.isExplicitlyDisabled else { return }
        do {
            if let credential = try self.remoteCodexBarTokenStore.loadCredential() {
                self.remoteCodexBarServerURLStorage = credential.serverURL
                self.remoteCodexBarBearerTokenStorage = credential.bearerToken
                self.remoteCodexBarAllowsPlainHTTPStorage = credential.allowsPlainHTTP
                self.userDefaults.set(credential.serverURL, forKey: "remoteCodexBarServerURL")
            } else {
                self.remoteCodexBarBearerTokenStorage = ""
                self.remoteCodexBarAllowsPlainHTTPStorage = false
            }
            self.remoteCodexBarSecretError = nil
            self.remoteCodexBarTokenLoadNeedsRetry = false
            self.remoteCodexBarConfigurationRevision &+= 1
            self.noteBackgroundWorkSettingsChanged()
        } catch {
            self.remoteCodexBarSecretError = error.localizedDescription
            self.remoteCodexBarTokenLoadNeedsRetry =
                error as? RemoteCodexBarTokenStoreError == .temporarilyUnavailable
        }
    }

    var remoteCodexBarConfiguration: RemoteCodexBarConfiguration? {
        RemoteCodexBarConfiguration.resolve(
            serverURL: self.remoteCodexBarServerURL,
            bearerToken: self.remoteCodexBarBearerToken,
            allowsPlainHTTP: self.remoteCodexBarAllowsPlainHTTP)
    }

    func remoteCodexBarURLValidationMessage(for serverURL: String) -> String? {
        let raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard ProviderEndpointOverrideValidator().validatedURLAllowingRemoteCodexBarHTTP(raw) != nil else {
            return "Use HTTPS, or HTTP only for loopback, private-network, or Tailscale/CGNAT hosts. " +
                "User info is not allowed."
        }
        guard URLComponents(string: raw)?.query == nil, URLComponents(string: raw)?.fragment == nil else {
            return "The server URL cannot include a query or fragment."
        }
        return nil
    }

    private func remoteCodexBarStoredCredential(
        serverURL: String,
        bearerToken: String,
        allowsPlainHTTP: Bool) -> RemoteCodexBarStoredCredential?
    {
        guard RemoteCodexBarConfiguration.resolve(
            serverURL: serverURL,
            bearerToken: bearerToken,
            allowsPlainHTTP: allowsPlainHTTP) != nil
        else { return nil }
        return RemoteCodexBarStoredCredential(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            bearerToken: bearerToken.trimmingCharacters(in: .whitespacesAndNewlines),
            allowsPlainHTTP: allowsPlainHTTP)
    }
}
