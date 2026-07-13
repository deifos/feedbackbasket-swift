import Foundation
import Security

struct FeedbackThreadCredential: Codable, Equatable, Sendable {
    let feedbackId: String
    let accessToken: String
}

enum FeedbackBasketMessageSender: String, Equatable, Sendable {
    case owner = "OWNER"
    case visitor = "VISITOR"
}

struct FeedbackBasketMessage: Equatable, Identifiable, Sendable {
    let id: String
    let sender: FeedbackBasketMessageSender
    let content: String
    let sentByName: String?
    let createdAt: Date
}

struct FeedbackReplyInbox: Equatable, Sendable {
    static let empty = FeedbackReplyInbox(conversations: [])

    let conversations: [FeedbackConversation]

    var unreadCount: Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }
}

struct FeedbackConversation: Equatable, Identifiable, Sendable {
    var id: String { credential.feedbackId }

    let credential: FeedbackThreadCredential
    let originalContent: String?
    let messages: [FeedbackBasketMessage]
    let visitorRepliesEnabled: Bool
    let unreadCount: Int
}

protocol FeedbackThreadStore: Sendable {
    func load(for baseURL: URL) async throws -> [FeedbackThreadCredential]
    func save(_ credential: FeedbackThreadCredential, for baseURL: URL) async throws
}

actor KeychainFeedbackThreadStore: FeedbackThreadStore {
    private let service = "com.feedbackbasket.sdk.reply-threads"
    private let maximumThreadCount = 50

    func load(for baseURL: URL) throws -> [FeedbackThreadCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: baseURL),
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainThreadStoreError.unexpectedStatus(status)
        }
        return try JSONDecoder().decode([FeedbackThreadCredential].self, from: data)
    }

    func save(_ credential: FeedbackThreadCredential, for baseURL: URL) throws {
        var credentials = try load(for: baseURL)
        credentials.removeAll { $0.feedbackId == credential.feedbackId }
        credentials.append(credential)
        if credentials.count > maximumThreadCount {
            credentials.removeFirst(credentials.count - maximumThreadCount)
        }

        let data = try JSONEncoder().encode(credentials)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: baseURL),
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainThreadStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainThreadStoreError.unexpectedStatus(addStatus)
        }
    }

    private func account(for baseURL: URL) -> String {
        baseURL.absoluteString
    }
}

private enum KeychainThreadStoreError: Error {
    case unexpectedStatus(OSStatus)
}
