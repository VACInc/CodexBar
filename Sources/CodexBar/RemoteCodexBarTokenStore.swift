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
    func storeCredential(_ credential: RemoteCodexBarStoredCredential?) throws
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
        case .interactionRequired, .temporarilyUnavailable:
            throw RemoteCodexBarTokenStoreError.temporarilyUnavailable
        case let .failure(status):
            throw Self.readError(for: OSStatus(status))
        }

        var result: CFTypeRef?
        var query = self.baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        KeychainNoUIQuery.apply(to: &query)

        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return try self.migrateLegacyCredential()
        }
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
        case .interactionRequired, .temporarilyUnavailable, .failure:
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
    case temporarilyUnavailable
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidData: "The saved remote CodexBar token is invalid."
        case .temporarilyUnavailable: "The saved remote CodexBar token is temporarily unavailable."
        case .writeFailed: "The remote CodexBar token could not be saved securely."
        }
    }
}
