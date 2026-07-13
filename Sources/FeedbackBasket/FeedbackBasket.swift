import Foundation
import Security
import UIKit

/// Optional information about the person sending feedback.
public struct FeedbackBasketUser: Sendable {
    /// The application's stable user identifier.
    public let id: String?
    /// The user's email address, when available.
    public let email: String?

    /// Creates user information to attach to feedback submissions.
    public init(id: String? = nil, email: String? = nil) {
        self.id = id
        self.email = email
    }
}

/// The kind of feedback being submitted.
public enum FeedbackBasketCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A report that something is not working as expected.
    case bug = "BUG"
    /// A request for new product behavior.
    case featureRequest = "FEATURE_REQUEST"
    /// A suggestion to improve existing behavior.
    case improvement = "IMPROVEMENT"
    /// A question from the user.
    case question = "QUESTION"

    /// A stable identifier suitable for SwiftUI collections.
    public var id: String { rawValue }

    /// A human-readable category name for feedback forms.
    public var label: String {
        switch self {
        case .bug: "Something isn't working"
        case .featureRequest: "A feature idea"
        case .improvement: "An improvement"
        case .question: "A question"
        }
    }
}

/// Errors produced by the FeedbackBasket SDK.
public enum FeedbackBasketError: LocalizedError {
    /// The SDK was used before it was configured.
    case notConfigured
    /// The server returned a response the SDK could not understand.
    case invalidResponse
    /// The server rejected the request with a user-readable reason.
    case rejected(String)

    /// A localized description suitable for displaying in an app.
    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Configure FeedbackBasket before presenting or submitting feedback."
        case .invalidResponse: "FeedbackBasket returned an unexpected response."
        case .rejected(let message): message
        }
    }
}

@MainActor
/// The main entry point for configuring and submitting FeedbackBasket feedback.
public enum FeedbackBasket {
    /// The current SDK version.
    public nonisolated static let sdkVersion = "0.2.0"

    private static var client: FeedbackBasketClient?
    static var configuredUser: FeedbackBasketUser?

    /// Configures the SDK and schedules a non-blocking connection heartbeat.
    ///
    /// Calling this method again replaces the previous configuration.
    public static func configure(
        projectKey: String,
        user: FeedbackBasketUser? = nil,
        context: [String: String] = [:],
        baseURL: URL = URL(string: "https://feedbackbasket.com")!
    ) {
        let automaticContext = FeedbackBasketEnvironment.capture()
        let mergedContext = automaticContext.merging(context) { _, supplied in supplied }
        let newClient = FeedbackBasketClient(
            projectKey: projectKey,
            baseURL: baseURL,
            user: user,
            defaultContext: mergedContext
        )
        client = newClient
        configuredUser = user
        Task { await newClient.sendHeartbeatIfNeeded() }
    }

    /// Submits feedback using the active configuration.
    public static func submitFeedback(
        message: String,
        category: FeedbackBasketCategory? = nil,
        email: String? = nil,
        context: [String: String] = [:]
    ) async throws {
        guard let client else { throw FeedbackBasketError.notConfigured }
        try await client.submit(
            message: message,
            category: category,
            email: email,
            context: context
        )
    }

    static func loadReplies() async -> FeedbackReplyInbox {
        guard let client else { return .empty }
        return await client.loadReplies()
    }

    static func markRepliesSeen(in threads: [FeedbackThreadCredential]) async {
        guard let client else { return }
        await client.markRepliesSeen(in: threads)
    }

#if DEBUG
    static func resetForTesting() {
        client = nil
        configuredUser = nil
    }
#endif
}

protocol FeedbackBasketTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: FeedbackBasketTransport {}

actor FeedbackBasketClient {
    private let projectKey: String
    private let baseURL: URL
    private let user: FeedbackBasketUser?
    private let defaultContext: [String: String]
    private let transport: any FeedbackBasketTransport
    private let threadStore: any FeedbackThreadStore
    private let heartbeatDefaults: UserDefaults
    private let installationIdentifier: @Sendable () -> String
    private let now: @Sendable () -> Date

    init(
        projectKey: String,
        baseURL: URL,
        user: FeedbackBasketUser?,
        defaultContext: [String: String],
        transport: any FeedbackBasketTransport = URLSession.shared,
        threadStore: any FeedbackThreadStore = KeychainFeedbackThreadStore(),
        heartbeatDefaults: UserDefaults = .standard,
        installationIdentifier: @escaping @Sendable () -> String = { InstallationIdentifier.value },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.projectKey = projectKey
        self.baseURL = baseURL
        self.user = user
        self.defaultContext = defaultContext
        self.transport = transport
        self.threadStore = threadStore
        self.heartbeatDefaults = heartbeatDefaults
        self.installationIdentifier = installationIdentifier
        self.now = now
    }

    func submit(
        message: String,
        category: FeedbackBasketCategory?,
        email: String?,
        context: [String: String]
    ) async throws {
        let payload = FeedbackPayload(
            projectKey: projectKey,
            content: message,
            email: email ?? user?.email,
            category: category,
            channel: "sdk",
            context: defaultContext
                .merging(context) { _, supplied in supplied }
                .merging(user?.id.map { ["userId": $0] } ?? [:]) { _, supplied in supplied }
        )
        let data = try await send(path: "api/sdk/feedback", payload: payload)
        guard !data.isEmpty else { return }

        let response: FeedbackSubmissionResponse
        do {
            response = try JSONDecoder().decode(FeedbackSubmissionResponse.self, from: data)
        } catch {
            throw FeedbackBasketError.invalidResponse
        }
        if let accessToken = response.accessToken {
            let credential = FeedbackThreadCredential(
                feedbackId: response.id,
                accessToken: accessToken
            )
            try await threadStore.save(credential, for: baseURL)
        }
    }

    func loadReplies() async -> FeedbackReplyInbox {
        guard let credentials = try? await threadStore.load(for: baseURL) else {
            return .empty
        }

        var replies: [FeedbackBasketReply] = []
        var threadsToAcknowledge: [FeedbackThreadCredential] = []
        for credential in credentials {
            do {
                var request = URLRequest(
                    url: endpoint(
                        pathComponents: [
                            "api", "widget", "feedback", credential.feedbackId, "messages",
                        ]
                    )
                )
                request.httpMethod = "GET"
                request.setValue(
                    "Bearer \(credential.accessToken)",
                    forHTTPHeaderField: "Authorization"
                )
                let data = try await perform(request)
                let response = try JSONDecoder().decode(FeedbackMessagesResponse.self, from: data)
                let threadReplies = response.messages.compactMap(\.reply)
                if !threadReplies.isEmpty {
                    replies.append(contentsOf: threadReplies)
                    threadsToAcknowledge.append(credential)
                }
            } catch {
                // Reply retrieval must never prevent the feedback form from opening.
            }
        }

        return FeedbackReplyInbox(
            replies: replies.sorted { $0.createdAt < $1.createdAt },
            threadsToAcknowledge: threadsToAcknowledge
        )
    }

    func markRepliesSeen(in threads: [FeedbackThreadCredential]) async {
        for credential in threads {
            do {
                var request = URLRequest(
                    url: endpoint(
                        pathComponents: [
                            "api", "widget", "feedback", credential.feedbackId, "seen",
                        ]
                    )
                )
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(
                    SeenPayload(token: credential.accessToken)
                )
                _ = try await perform(request)
            } catch {
                // A later sheet presentation can retry the acknowledgement.
            }
        }
    }

    func sendHeartbeatIfNeeded() async {
        let defaultsKey = "FeedbackBasket.lastHeartbeat.\(projectKey)"
        let lastHeartbeat = heartbeatDefaults.object(forKey: defaultsKey) as? Date
        if let lastHeartbeat, now().timeIntervalSince(lastHeartbeat) < 86_400 { return }

        let payload = HeartbeatPayload(
            projectKey: projectKey,
            platform: "ios",
            sdkVersion: FeedbackBasket.sdkVersion,
            bundleId: defaultContext["bundleId"],
            appVersion: defaultContext["appVersion"],
            appBuild: defaultContext["appBuild"],
            installationId: installationIdentifier()
        )
        do {
            _ = try await send(path: "api/sdk/heartbeat", payload: payload)
            heartbeatDefaults.set(now(), forKey: defaultsKey)
        } catch {
            // Connection verification is retried on the next app launch.
        }
    }

    private func send<Payload: Encodable>(path: String, payload: Payload) async throws -> Data {
        let components = path.split(separator: "/").map(String.init)
        var request = URLRequest(url: endpoint(pathComponents: components))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackBasketError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            guard let apiError = try? JSONDecoder().decode(APIError.self, from: data) else {
                throw FeedbackBasketError.invalidResponse
            }
            throw FeedbackBasketError.rejected(apiError.error)
        }
        return data
    }

    private func endpoint(pathComponents: [String]) -> URL {
        pathComponents.reduce(baseURL) { url, component in
            url.appendingPathComponent(component)
        }
    }
}

private struct FeedbackPayload: Encodable {
    let projectKey: String
    let content: String
    let email: String?
    let category: FeedbackBasketCategory?
    let channel: String
    let context: [String: String]
}

private struct HeartbeatPayload: Encodable {
    let projectKey: String
    let platform: String
    let sdkVersion: String
    let bundleId: String?
    let appVersion: String?
    let appBuild: String?
    let installationId: String
}

private struct FeedbackSubmissionResponse: Decodable {
    let id: String
    let accessToken: String?
}

private struct FeedbackMessagesResponse: Decodable {
    let messages: [FeedbackMessageResponse]
}

private struct FeedbackMessageResponse: Decodable {
    let id: String
    let senderType: String
    let content: String
    let sentByName: String?
    let createdAt: String

    var reply: FeedbackBasketReply? {
        guard
            senderType == "OWNER",
            let date = FeedbackBasketDateParser.date(from: createdAt)
        else {
            return nil
        }
        return FeedbackBasketReply(
            id: id,
            content: content,
            sentByName: sentByName,
            createdAt: date
        )
    }
}

private struct SeenPayload: Encodable {
    let token: String
}

private enum FeedbackBasketDateParser {
    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private struct APIError: Decodable {
    let error: String
}

@MainActor
enum FeedbackBasketEnvironment {
    static func capture() -> [String: String] {
        let bundle = Bundle.main
        return [
            "platform": "ios",
            "appVersion": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "appBuild": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "bundleId": bundle.bundleIdentifier ?? "",
            "osVersion": UIDevice.current.systemVersion,
            "device": UIDevice.current.model,
            "locale": Locale.current.identifier,
            "sdkVersion": FeedbackBasket.sdkVersion,
        ].filter { !$0.value.isEmpty }
    }
}

enum InstallationIdentifier {
    private static let cache = InstallationIdentifierCache()

    static var value: String {
        cache.withLock {
            if let cached = cache.value { return cached }

            let identifier = keychainValue() ?? createKeychainValue()
            cache.value = identifier
            return identifier
        }
    }

    private static func keychainValue() -> String? {
        let account = "installation-id"
        let service = "com.feedbackbasket.sdk"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let identifier = String(data: data, encoding: .utf8) {
            return identifier
        }
        return nil
    }

    private static func createKeychainValue() -> String {
        let identifier = UUID().uuidString
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.feedbackbasket.sdk",
            kSecAttrAccount as String: "installation-id",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(identifier.utf8),
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
        return identifier
    }
}

private final class InstallationIdentifierCache: @unchecked Sendable {
    private let lock = NSLock()
    var value: String?

    func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
