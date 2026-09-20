import CodexBarCore
import Foundation

extension SettingsStore {
    var remoteCodexBarRemoteOnlyEnabled: Bool {
        get { self.defaultsState.remoteCodexBarRemoteOnlyEnabled }
        set {
            guard self.defaultsState.remoteCodexBarRemoteOnlyEnabled != newValue else { return }
            self.defaultsState.remoteCodexBarRemoteOnlyEnabled = newValue
            self.userDefaults.set(newValue, forKey: "remoteCodexBarRemoteOnlyEnabled")
            self.remoteCodexBarConfigurationRevision &+= 1
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var usesRemoteCodexBarProvidersOnly: Bool {
        self.remoteCodexBarRemoteOnlyEnabled && self.remoteCodexBarConfiguration != nil
    }

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
        // Do not report a successful connection unless the credential will survive an app restart.
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
        self.userDefaults.set(storesPlainHTTPConsent, forKey: "remoteCodexBarAllowsPlainHTTP")
        self.remoteCodexBarTokenNeedsAuthorization = false
        if credential == nil {
            self.remoteCodexBarRemoteOnlyEnabled = false
        }
        self.remoteCodexBarTokenLoadNeedsRetry = false
        self.remoteCodexBarSecretError = nil
        self.remoteCodexBarConfigurationRevision &+= 1
        self.noteBackgroundWorkSettingsChanged()
        return true
    }

    func retryRemoteCodexBarTokenLoadIfNeeded() {
        if self.remoteCodexBarTokenLoadNeedsRetry {
            guard !KeychainAccessGate.isExplicitlyDisabled else { return }
            do {
                try self.applyRecoveredRemoteCodexBarCredential(
                    self.remoteCodexBarTokenStore.loadCredential())
            } catch {
                self.remoteCodexBarSecretError = error.localizedDescription
                self.remoteCodexBarTokenLoadNeedsRetry =
                    error as? RemoteCodexBarTokenStoreError == .temporarilyUnavailable
                self.remoteCodexBarTokenNeedsAuthorization =
                    error as? RemoteCodexBarTokenStoreError == .interactionRequired
            }
            return
        }
        // Recovery presents a system prompt, so attempt it once per launch and leave any further
        // attempt to the explicit control in Preferences.
        guard self.remoteCodexBarTokenNeedsAuthorization,
              !self.remoteCodexBarTokenAuthorizationAttempted
        else { return }
        self.authorizeRemoteCodexBarTokenAccess()
    }

    /// Re-reads the saved credential with Keychain UI allowed. A new build's code signature is not on the
    /// existing item's access-control list, so without this the saved token stays unreadable and the user
    /// has to retype it after every update.
    func authorizeRemoteCodexBarTokenAccess() {
        guard !KeychainAccessGate.isExplicitlyDisabled else { return }
        self.remoteCodexBarTokenAuthorizationAttempted = true
        do {
            let credential = try self.remoteCodexBarTokenStore.loadCredentialAllowingInteraction()
            self.applyRecoveredRemoteCodexBarCredential(credential)
            self.remoteCodexBarTokenNeedsAuthorization = false
        } catch {
            self.remoteCodexBarSecretError = error.localizedDescription
            self.remoteCodexBarTokenLoadNeedsRetry =
                error as? RemoteCodexBarTokenStoreError == .temporarilyUnavailable
        }
    }

    private func applyRecoveredRemoteCodexBarCredential(_ credential: RemoteCodexBarStoredCredential?) {
        if let credential {
            self.remoteCodexBarServerURLStorage = credential.serverURL
            self.remoteCodexBarBearerTokenStorage = credential.bearerToken
            self.remoteCodexBarAllowsPlainHTTPStorage = credential.allowsPlainHTTP
            self.userDefaults.set(credential.serverURL, forKey: "remoteCodexBarServerURL")
            self.userDefaults.set(credential.allowsPlainHTTP, forKey: "remoteCodexBarAllowsPlainHTTP")
        } else {
            self.remoteCodexBarBearerTokenStorage = ""
            self.remoteCodexBarAllowsPlainHTTPStorage = false
        }
        self.remoteCodexBarSecretError = nil
        self.remoteCodexBarTokenLoadNeedsRetry = false
        self.remoteCodexBarTokenNeedsAuthorization = false
        self.remoteCodexBarConfigurationRevision &+= 1
        self.noteBackgroundWorkSettingsChanged()
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
