import CodexBarCore
import Foundation

protocol RemoteCodexBarTokenStoring: Sendable {
    func loadToken() throws -> String?
    func storeToken(_ token: String?) throws
}

struct KeychainRemoteCodexBarTokenStore: RemoteCodexBarTokenStoring {
    private static let key = KeychainCacheStore.Key(
        category: "remote-codexbar-secret",
        identifier: "dashboard-bearer-token")

    func loadToken() throws -> String? {
        switch KeychainCacheStore.load(key: Self.key, as: String.self) {
        case let .found(token):
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .missing:
            return nil
        case .temporarilyUnavailable:
            throw RemoteCodexBarTokenStoreError.temporarilyUnavailable
        case .invalid:
            throw RemoteCodexBarTokenStoreError.invalidData
        }
    }

    func storeToken(_ token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            guard KeychainCacheStore.storeResult(key: Self.key, entry: trimmed) else {
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
