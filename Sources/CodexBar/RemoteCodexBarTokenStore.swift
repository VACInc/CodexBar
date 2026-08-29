import CodexBarCore
import Foundation

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
    private static let key = KeychainCacheStore.Key(
        category: "remote-codexbar-secret",
        identifier: "dashboard-bearer-token")

    func loadCredential() throws -> RemoteCodexBarStoredCredential? {
        switch KeychainCacheStore.load(key: Self.key, as: RemoteCodexBarStoredCredential.self) {
        case let .found(credential):
            let token = credential.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return nil }
            return RemoteCodexBarStoredCredential(
                serverURL: credential.serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                bearerToken: token,
                allowsPlainHTTP: credential.allowsPlainHTTP)
        case .missing:
            return nil
        case .temporarilyUnavailable:
            throw RemoteCodexBarTokenStoreError.temporarilyUnavailable
        case .invalid:
            throw RemoteCodexBarTokenStoreError.invalidData
        }
    }

    func storeCredential(_ credential: RemoteCodexBarStoredCredential?) throws {
        if let credential {
            guard KeychainCacheStore.storeResult(key: Self.key, entry: credential) else {
                throw RemoteCodexBarTokenStoreError.writeFailed
            }
        } else {
            switch KeychainCacheStore.clearResult(key: Self.key) {
            case .removed, .missing:
                break
            case .failed:
                throw RemoteCodexBarTokenStoreError.writeFailed
            }
        }
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
