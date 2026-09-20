import CodexBarCore
import Foundation
import Security

struct RemoteCodexBarStoredCredential: Codable, Equatable, Sendable {
    let serverURL: String
    let bearerToken: String
    let allowsPlainHTTP: Bool
}

protocol RemoteCodexBarTokenStoring: Sendable {
    func loadCredential() throws -> RemoteCodexBarStoredCredential?

    /// Reads the credential with Keychain UI allowed, then re-owns the item so later launches of the
    /// same binary read it silently. Only call this in response to `RemoteCodexBarTokenStoreError
    /// .interactionRequired`, because it can present a system authorization prompt.
    func loadCredentialAllowingInteraction() throws -> RemoteCodexBarStoredCredential?

    func storeCredential(_ credential: RemoteCodexBarStoredCredential?) throws
}

extension RemoteCodexBarTokenStoring {
    func loadCredentialAllowingInteraction() throws -> RemoteCodexBarStoredCredential? {
        try self.loadCredential()
    }
}

struct KeychainRemoteCodexBarTokenStore: RemoteCodexBarTokenStoring {
    private static let legacyCacheKey = KeychainCacheStore.Key(
        category: "remote-codexbar-secret",
        identifier: "dashboard-bearer-token")

    private let service: String
    private let account: String

    init(
        service: String = "com.steipete.CodexBar",
        account: String = "remote-codexbar-dashboard-credential")
    {
        self.service = service
        self.account = account
    }

    func loadCredential() throws -> RemoteCodexBarStoredCredential? {
        guard !KeychainAccessGate.isDisabled else {
            throw RemoteCodexBarTokenStoreError.temporarilyUnavailable
        }
        switch KeychainAccessPreflight.checkGenericPassword(service: self.service, account: self.account) {
        case .allowed:
            break
        case .notFound:
            return try self.migrateLegacyCredential()
        case .interactionRequired:
            // The item exists but this binary is not on its access-control list. Ad-hoc preview builds
            // hit this on every rebuild because their designated requirement is the changing cdhash.
            // Recovery needs a user-visible prompt, so keep it distinct from a transient failure.
            throw RemoteCodexBarTokenStoreError.interactionRequired
        case .temporarilyUnavailable:
            throw RemoteCodexBarTokenStoreError.temporarilyUnavailable
        case let .failure(status):
            throw Self.readError(for: OSStatus(status))
        }

        var query = self.baseQuery
        KeychainNoUIQuery.apply(to: &query)
        switch try self.copyCredential(query: query) {
        case .none:
            return try self.migrateLegacyCredential()
        case let .some(credential):
            return credential
        }
    }

    func loadCredentialAllowingInteraction() throws -> RemoteCodexBarStoredCredential? {
        guard !KeychainAccessGate.isDisabled else {
            throw RemoteCodexBarTokenStoreError.temporarilyUnavailable
        }
        var query = self.baseQuery
        query[kSecUseOperationPrompt as String] = String(
            localized: "CodexBar needs access to its saved sync token.")
        guard let credential = try self.copyCredential(query: query) else {
            return try self.migrateLegacyCredential()
        }
        // Re-own the item under this binary's identity so the next launch reads it without a prompt.
        // A failure here only costs another prompt later, so it must not discard a recovered token.
        try? self.reown(credential)
        return credential
    }

    /// Returns `nil` when the item is absent; the caller decides whether to fall back to migration.
    private func copyCredential(query: [String: Any]) throws -> RemoteCodexBarStoredCredential? {
        var result: CFTypeRef?
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.readError(for: status) }
        guard let data = result as? Data,
              let credential = try? JSONDecoder().decode(RemoteCodexBarStoredCredential.self, from: data)
        else {
            throw RemoteCodexBarTokenStoreError.invalidData
        }
        let token = credential.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        return RemoteCodexBarStoredCredential(
            serverURL: credential.serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            bearerToken: token,
            allowsPlainHTTP: credential.allowsPlainHTTP)
    }

    /// Deletes and re-adds the item. Deletion does not decrypt the payload, so it succeeds without the
    /// decrypt ACL the current binary is missing, and the fresh record is owned by this binary.
    private func reown(_ credential: RemoteCodexBarStoredCredential) throws {
        var deleteQuery = self.baseQuery
        KeychainNoUIQuery.apply(to: &deleteQuery)
        let deleteStatus = KeychainSecurity.delete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw RemoteCodexBarTokenStoreError.writeFailed
        }
        var query = self.baseQuery
        KeychainNoUIQuery.apply(to: &query)
        query[kSecValueData as String] = try JSONEncoder().encode(credential)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard KeychainSecurity.add(query as CFDictionary, nil) == errSecSuccess else {
            throw RemoteCodexBarTokenStoreError.writeFailed
        }
    }

    func storeCredential(_ credential: RemoteCodexBarStoredCredential?) throws {
        guard !KeychainAccessGate.isDisabled else {
            throw RemoteCodexBarTokenStoreError.writeFailed
        }
        // Keep a non-secret tombstone instead of deleting the new record. If an inaccessible legacy
        // cache item survives best-effort cleanup, the tombstone prevents it from being migrated later.
        let storedCredential = credential ?? RemoteCodexBarStoredCredential(
            serverURL: "",
            bearerToken: "",
            allowsPlainHTTP: false)

        let data = try JSONEncoder().encode(storedCredential)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var query = self.baseQuery
        KeychainNoUIQuery.apply(to: &query)
        switch KeychainAccessPreflight.checkGenericPassword(service: self.service, account: self.account) {
        case .allowed:
            guard KeychainSecurity.update(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                throw RemoteCodexBarTokenStoreError.writeFailed
            }
        case .notFound:
            for (key, value) in attributes {
                query[key] = value
            }
            guard KeychainSecurity.add(query as CFDictionary, nil) == errSecSuccess else {
                throw RemoteCodexBarTokenStoreError.writeFailed
            }
        case .interactionRequired:
            // An existing record this binary cannot decrypt still blocks `update`. Replacing it needs no
            // decrypt access and leaves the new record owned by this binary, so saving succeeds without
            // a prompt instead of dropping the user into session-only mode on every ad-hoc rebuild.
            try self.reown(storedCredential)
        case .temporarilyUnavailable, .failure:
            throw RemoteCodexBarTokenStoreError.writeFailed
        }
        _ = KeychainCacheStore.clearResult(key: Self.legacyCacheKey)
    }

    func deleteStoredItemForTesting() throws {
        switch KeychainAccessPreflight.checkGenericPassword(service: self.service, account: self.account) {
        case .allowed:
            var query = self.baseQuery
            KeychainNoUIQuery.apply(to: &query)
            guard KeychainSecurity.delete(query as CFDictionary) == errSecSuccess else {
                throw RemoteCodexBarTokenStoreError.writeFailed
            }
        case .notFound:
            return
        case .interactionRequired, .temporarilyUnavailable, .failure:
            throw RemoteCodexBarTokenStoreError.writeFailed
        }
    }

    private func migrateLegacyCredential() throws -> RemoteCodexBarStoredCredential? {
        switch KeychainCacheStore.load(key: Self.legacyCacheKey, as: RemoteCodexBarStoredCredential.self) {
        case let .found(credential):
            try self.storeCredential(credential)
            return credential
        case .missing:
            return nil
        case .interactionRequired, .temporarilyUnavailable:
            throw RemoteCodexBarTokenStoreError.temporarilyUnavailable
        case .invalid:
            throw RemoteCodexBarTokenStoreError.invalidData
        }
    }

    static func readError(for status: OSStatus) -> RemoteCodexBarTokenStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable:
            .temporarilyUnavailable
        default:
            .invalidData
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
    }
}

enum RemoteCodexBarTokenStoreError: LocalizedError, Equatable {
    case invalidData
    case interactionRequired
    case temporarilyUnavailable
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidData: "The saved remote CodexBar token is invalid."
        case .interactionRequired:
            "The saved remote CodexBar token needs your permission before this build can read it."
        case .temporarilyUnavailable: "The saved remote CodexBar token is temporarily unavailable."
        case .writeFailed: "The remote CodexBar token could not be saved securely."
        }
    }
}
