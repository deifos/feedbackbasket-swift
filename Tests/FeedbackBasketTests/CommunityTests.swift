import Foundation
import XCTest
@testable import FeedbackBasket

private actor CommunityTransport: FeedbackBasketTransport {
    var requests: [URLRequest] = []
    let json: String
    let status: Int
    init(_ json: String, status: Int = 200) { self.json = json; self.status = status }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func last() -> URLRequest? { requests.last }
    func count() -> Int { requests.count }
}
final class CommunityTests: XCTestCase {
    func testBoardPaginationAndVotesDecodeWithoutCredentials() async throws {
        let transport = CommunityTransport(#"{"board":{"name":"Ideas","allowAnonymousPosting":true,"readOnly":false},"feedback":[{"id":"f1","content":"Idea","fullContent":"Full idea","status":"OPEN","createdAt":"2026-10-19T00:00:00Z","voteCount":12,"hasVoted":true}],"total":21,"page":1,"limit":20}"#)
        let client = FeedbackBasketCommunity(baseURL: URL(string: "https://sdk.test")!, transport: transport)
        let result = try await client.board(slug: "ideas")
        XCTAssertEqual(result.feedback[0].voteCount, 12)
        XCTAssertTrue(result.hasMore)
        let request = await transport.last()
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request?.url?.path, "/api/board/ideas")
        XCTAssertTrue(request?.url?.query?.contains("sort=votes") == true)
    }
    func testVoteIsSentOnceAndUsesFeedbackID() async throws {
        let transport = CommunityTransport(#"{"voted":true,"voteCount":3}"#)
        let client = FeedbackBasketCommunity(baseURL: URL(string: "https://sdk.test")!, transport: transport)
        let result = try await client.toggleVote(slug: "ideas", feedbackId: "f1")
        XCTAssertEqual(result.voteCount, 3)
        let request = await transport.last()
        XCTAssertEqual(request?.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: request!.httpBody!) as? [String: String]
        XCTAssertEqual(body?["feedbackId"], "f1")
        let count = await transport.count()
        XCTAssertEqual(count, 1)
    }
    func testHiddenBoardErrorAndInvalidSlug() async throws {
        let transport = CommunityTransport(#"{"error":"Board not found"}"#, status: 404)
        let client = FeedbackBasketCommunity(baseURL: URL(string: "https://sdk.test")!, transport: transport)
        do { _ = try await client.board(slug: "hidden"); XCTFail("Expected error") }
        catch { XCTAssertEqual(error.localizedDescription, "Board not found") }
        do { _ = try await client.board(slug: "../private"); XCTFail("Expected error") } catch {}
        let count = await transport.count()
        XCTAssertEqual(count, 1)
    }
    func testRoadmapDecodesNullableDates() async throws {
        let transport = CommunityTransport(#"{"project":{"name":"App","slug":"ideas"},"config":{"showDueDates":true,"showScheduledDates":false,"primaryColor":"#000000"},"cards":[{"id":"c1","title":"New feature","status":"TODO","position":0,"createdAt":"2026-10-19T00:00:00Z","dueDate":null}]}"#)
        let client = FeedbackBasketCommunity(baseURL: URL(string: "https://sdk.test")!, transport: transport)
        let roadmap = try await client.roadmap(slug: "ideas")
        XCTAssertEqual(roadmap.cards[0].position, 0)
        XCTAssertNil(roadmap.cards[0].dueDate)
        XCTAssertNil(roadmap.config.hiddenColumns)
    }
    func testRoadmapDecodesHiddenColumns() async throws {
        let transport = CommunityTransport(#"{"project":{"name":"App","slug":"ideas"},"config":{"showDueDates":true,"showScheduledDates":true,"primaryColor":"#dc2626","hiddenColumns":["IN_REVIEW"]},"cards":[]}"#)
        let client = FeedbackBasketCommunity(baseURL: URL(string: "https://sdk.test")!, transport: transport)
        let roadmap = try await client.roadmap(slug: "ideas")
        XCTAssertEqual(roadmap.config.hiddenColumns, ["IN_REVIEW"])
    }
    func testSubmissionUsesPendingReviewEndpoint() async throws {
        let transport = CommunityTransport(#"{"success":true,"id":"f2"}"#, status: 201)
        let client = FeedbackBasketCommunity(baseURL: URL(string: "https://sdk.test")!, transport: transport)
        let result = try await client.submit(slug: "ideas", content: "Add shortcuts")
        XCTAssertTrue(result.success)
        let request = await transport.last()
        XCTAssertEqual(request?.url?.path, "/api/board/ideas/feedback")
    }
}
