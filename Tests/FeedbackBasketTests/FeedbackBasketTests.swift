import Foundation
import XCTest
@testable import FeedbackBasket

final class FeedbackBasketTests: XCTestCase {
    private let baseURL = URL(string: "https://sdk.test")!

    @MainActor
    override func tearDown() {
        FeedbackBasket.resetForTesting()
        super.tearDown()
    }

    func testFeedbackPayloadIncludesCoreFields() async throws {
        let transport = MockTransport.success()
        let client = makeClient(transport: transport, user: .init(email: "person@example.com"))

        try await client.submit(message: "Save is broken", category: .bug, email: nil, context: [:])

        let body = try await transport.lastJSON()
        XCTAssertEqual(body["projectKey"] as? String, "fb_mobile_test")
        XCTAssertEqual(body["content"] as? String, "Save is broken")
        XCTAssertEqual(body["category"] as? String, "BUG")
        XCTAssertEqual(body["email"] as? String, "person@example.com")
        XCTAssertEqual(body["channel"] as? String, "sdk")
    }

    @MainActor
    func testAutomaticContextIncludesAvailableMetadata() {
        let context = FeedbackBasketEnvironment.capture()

        XCTAssertEqual(context["platform"], "ios")
        XCTAssertEqual(context["sdkVersion"], FeedbackBasket.sdkVersion)
        XCTAssertNotNil(context["osVersion"])
        XCTAssertNotNil(context["device"])
        XCTAssertNotNil(context["locale"])
        assertMatchesBundleValue(context, key: "bundleId", expected: Bundle.main.bundleIdentifier)
        assertMatchesBundleValue(context, key: "appVersion", expected: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        assertMatchesBundleValue(context, key: "appBuild", expected: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    func testSuppliedContextOverridesAutomaticContext() async throws {
        let transport = MockTransport.success()
        let client = makeClient(transport: transport, defaultContext: ["platform": "ios", "screen": "Automatic"])

        try await client.submit(message: "Hello", category: nil, email: nil, context: ["screen": "Settings"])

        let body = try await transport.lastJSON()
        let context = try XCTUnwrap(body["context"] as? [String: String])
        XCTAssertEqual(context["screen"], "Settings")
        XCTAssertEqual(context["platform"], "ios")
    }

    func testSubmissionContextOverridesConfiguredContext() async throws {
        let transport = MockTransport.success()
        let client = makeClient(transport: transport, defaultContext: ["accountPlan": "free"])

        try await client.submit(message: "Hello", category: nil, email: nil, context: ["accountPlan": "pro"])

        let body = try await transport.lastJSON()
        let context = try XCTUnwrap(body["context"] as? [String: String])
        XCTAssertEqual(context["accountPlan"], "pro")
    }

    func testConfiguredUserIsIncluded() async throws {
        let transport = MockTransport.success()
        let client = makeClient(transport: transport, user: .init(id: "42", email: "person@example.com"))

        try await client.submit(message: "Hello", category: nil, email: nil, context: [:])

        let body = try await transport.lastJSON()
        let context = try XCTUnwrap(body["context"] as? [String: String])
        XCTAssertEqual(body["email"] as? String, "person@example.com")
        XCTAssertEqual(context["userId"], "42")
    }

    func testExplicitEmptyEmailDoesNotFallBackToConfiguredUser() async throws {
        let transport = MockTransport.success()
        let client = makeClient(transport: transport, user: .init(email: "person@example.com"))

        try await client.submit(message: "Hello", category: nil, email: "", context: [:])

        let body = try await transport.lastJSON()
        XCTAssertEqual(body["email"] as? String, "")
    }

    func testSuccessfulFeedbackResponseCompletes() async throws {
        let client = makeClient(transport: .success(statusCode: 204))
        try await client.submit(message: "Hello", category: .question, email: nil, context: [:])
    }

    func testSuccessfulFeedbackStoresReplyCredential() async throws {
        let store = MockThreadStore()
        let response = Data(
            #"{"success":true,"id":"feedback-123","accessToken":"thread-token"}"#.utf8
        )
        let client = makeClient(
            transport: .success(data: response),
            threadStore: store
        )

        try await client.submit(message: "Hello", category: nil, email: nil, context: [:])

        let credentials = try await store.load(for: baseURL)
        XCTAssertEqual(
            credentials,
            [FeedbackThreadCredential(feedbackId: "feedback-123", accessToken: "thread-token")]
        )
    }

    func testReplyFetchUsesBearerAuthorizationAndDecodesOwnerMessages() async throws {
        let store = MockThreadStore()
        try await store.save(
            FeedbackThreadCredential(feedbackId: "feedback-123", accessToken: "thread-token"),
            for: baseURL
        )
        let response = Data(
            #"{"messages":[{"id":"message-1","senderType":"OWNER","content":"Thanks — this is fixed.","sentByName":"Vlad","createdAt":"2026-07-13T15:30:00.000Z"}],"lastSeenAt":null}"#.utf8
        )
        let transport = MockTransport.success(data: response)
        let client = makeClient(transport: transport, threadStore: store)

        let inbox = await client.loadReplies()

        let request = try await transport.lastRequest()
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.path,
            "/api/widget/feedback/feedback-123/messages"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer thread-token")
        XCTAssertEqual(inbox.replies.count, 1)
        XCTAssertEqual(inbox.replies.first?.content, "Thanks — this is fixed.")
        XCTAssertEqual(inbox.replies.first?.sentByName, "Vlad")
        XCTAssertEqual(inbox.threadsToAcknowledge.count, 1)
    }

    func testSeenAcknowledgementPostsTokenInJSONBody() async throws {
        let transport = MockTransport.success()
        let client = makeClient(transport: transport)
        let credential = FeedbackThreadCredential(
            feedbackId: "feedback-123",
            accessToken: "thread-token"
        )

        await client.markRepliesSeen(in: [credential])

        let request = try await transport.lastRequest()
        let body = try await transport.lastJSON()
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/widget/feedback/feedback-123/seen")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(body["token"] as? String, "thread-token")
    }

    func testReplyFetchFailureReturnsEmptyInbox() async throws {
        let store = MockThreadStore()
        try await store.save(
            FeedbackThreadCredential(feedbackId: "feedback-123", accessToken: "thread-token"),
            for: baseURL
        )
        let client = makeClient(
            transport: MockTransport(error: TestError.offline),
            threadStore: store
        )

        let inbox = await client.loadReplies()

        XCTAssertEqual(inbox, .empty)
    }

    func testRejectedFeedbackUsesBackendMessage() async throws {
        let transport = MockTransport(statusCode: 422, data: Data(#"{"error":"Project key is invalid."}"#.utf8))
        let client = makeClient(transport: transport)

        do {
            try await client.submit(message: "Hello", category: nil, email: nil, context: [:])
            XCTFail("Expected submission to fail")
        } catch FeedbackBasketError.rejected(let message) {
            XCTAssertEqual(message, "Project key is invalid.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMalformedErrorResponseIsInvalidResponse() async throws {
        let client = makeClient(transport: MockTransport(statusCode: 500, data: Data("not-json".utf8)))

        do {
            try await client.submit(message: "Hello", category: nil, email: nil, context: [:])
            XCTFail("Expected submission to fail")
        } catch FeedbackBasketError.invalidResponse {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testSubmitBeforeConfigureThrowsNotConfigured() async throws {
        FeedbackBasket.resetForTesting()

        do {
            try await FeedbackBasket.submitFeedback(message: "Hello")
            XCTFail("Expected submission to fail")
        } catch FeedbackBasketError.notConfigured {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHeartbeatPayloadIncludesSDKAndApplicationMetadata() async throws {
        let transport = MockTransport.success()
        let client = makeClient(
            transport: transport,
            defaultContext: ["bundleId": "com.example.app", "appVersion": "2.4.1", "appBuild": "184"],
            installationIdentifier: "stable-installation"
        )

        await client.sendHeartbeatIfNeeded()

        let body = try await transport.lastJSON()
        XCTAssertEqual(body["projectKey"] as? String, "fb_mobile_test")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["sdkVersion"] as? String, FeedbackBasket.sdkVersion)
        XCTAssertEqual(body["bundleId"] as? String, "com.example.app")
        XCTAssertEqual(body["appVersion"] as? String, "2.4.1")
        XCTAssertEqual(body["appBuild"] as? String, "184")
        XCTAssertEqual(body["installationId"] as? String, "stable-installation")
    }

    func testSuccessfulHeartbeatRecordsThrottleTimestamp() async throws {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let client = makeClient(transport: .success(), defaults: defaults, now: now)

        await client.sendHeartbeatIfNeeded()

        XCTAssertEqual(defaults.object(forKey: heartbeatKey) as? Date, now)
    }

    func testFailedHeartbeatDoesNotRecordThrottleTimestamp() async throws {
        let defaults = makeDefaults()
        let client = makeClient(transport: MockTransport(error: TestError.offline), defaults: defaults)

        await client.sendHeartbeatIfNeeded()

        XCTAssertNil(defaults.object(forKey: heartbeatKey))
    }

    func testInstallationIdentifierIsStableAcrossReads() {
        XCTAssertEqual(InstallationIdentifier.value, InstallationIdentifier.value)
    }

    private var heartbeatKey: String { "FeedbackBasket.lastHeartbeat.fb_mobile_test" }

    private func makeClient(
        transport: MockTransport,
        threadStore: any FeedbackThreadStore = MockThreadStore(),
        user: FeedbackBasketUser? = nil,
        defaultContext: [String: String] = [:],
        defaults: UserDefaults? = nil,
        installationIdentifier: String = "installation-id",
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> FeedbackBasketClient {
        FeedbackBasketClient(
            projectKey: "fb_mobile_test",
            baseURL: baseURL,
            user: user,
            defaultContext: defaultContext,
            transport: transport,
            threadStore: threadStore,
            heartbeatDefaults: defaults ?? makeDefaults(),
            installationIdentifier: { installationIdentifier },
            now: { now }
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "FeedbackBasketTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    @MainActor
    private func assertMatchesBundleValue(_ context: [String: String], key: String, expected: String?) {
        if let expected, !expected.isEmpty {
            XCTAssertEqual(context[key], expected)
        } else {
            XCTAssertNil(context[key])
        }
    }
}

private enum TestError: Error {
    case offline
}

private actor MockTransport: FeedbackBasketTransport {
    private let statusCode: Int
    private let responseData: Data
    private let error: Error?
    private var requests: [URLRequest] = []

    init(statusCode: Int = 200, data: Data = Data(), error: Error? = nil) {
        self.statusCode = statusCode
        self.responseData = data
        self.error = error
    }

    static func success(statusCode: Int = 200, data: Data = Data()) -> MockTransport {
        MockTransport(statusCode: statusCode, data: data)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let error { throw error }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }

    func lastJSON() throws -> [String: Any] {
        let request = try XCTUnwrap(requests.last)
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func lastRequest() throws -> URLRequest {
        try XCTUnwrap(requests.last)
    }
}

private actor MockThreadStore: FeedbackThreadStore {
    private var storedCredentials: [FeedbackThreadCredential] = []

    func load(for baseURL: URL) throws -> [FeedbackThreadCredential] {
        storedCredentials
    }

    func save(_ credential: FeedbackThreadCredential, for baseURL: URL) throws {
        storedCredentials.removeAll { $0.feedbackId == credential.feedbackId }
        storedCredentials.append(credential)
    }
}
