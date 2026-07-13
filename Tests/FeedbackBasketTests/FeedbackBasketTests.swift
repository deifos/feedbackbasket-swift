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

    static func success(statusCode: Int = 200) -> MockTransport {
        MockTransport(statusCode: statusCode)
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
}
