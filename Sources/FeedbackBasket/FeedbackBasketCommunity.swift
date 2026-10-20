import Foundation

/// Public community access. This client never accepts an administrator token.
public actor FeedbackBasketCommunity {
    public static let contractVersion = "3.10.0"
    private let baseURL: URL
    private let transport: any FeedbackBasketTransport

    public init(baseURL: URL = URL(string: "https://feedbackbasket.com")!) {
        self.baseURL = baseURL
        self.transport = URLSession.shared
    }

    init(baseURL: URL, transport: any FeedbackBasketTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public enum Sort: String, Sendable { case votes, newest }

    /// Loads one page of approved feedback and the current viewer's vote state.
    public func board(slug: String, page: Int = 1, sort: Sort = .votes) async throws -> FeedbackBasketBoardPage {
        guard (1...100_000).contains(page) else { throw FeedbackBasketError.rejected("Invalid page") }
        return try await send(slug: slug, resource: "board", query: [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "sort", value: sort.rawValue)])
    }

    public func roadmap(slug: String) async throws -> FeedbackBasketPublicRoadmap {
        try await send(slug: slug, resource: "roadmap")
    }

    /// Toggles the current IP-based vote. Do not retry automatically: a second call removes the vote.
    public func toggleVote(slug: String, feedbackId: String) async throws -> FeedbackBasketVoteResult {
        try await send(slug: slug, resource: "board", suffix: "vote", body: ["feedbackId": feedbackId])
    }

    /// Submits feedback for review. It is not immediately published on the board.
    public func submit(slug: String, content: String, email: String? = nil) async throws -> FeedbackBasketBoardSubmission {
        var body = ["content": content]
        if let email { body["email"] = email }
        return try await send(slug: slug, resource: "board", suffix: "feedback", body: body)
    }

    private func send<T: Decodable>(slug: String, resource: String, suffix: String? = nil, query: [URLQueryItem] = [], body: [String: String]? = nil) async throws -> T {
        guard !slug.isEmpty, slug.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
            throw FeedbackBasketError.rejected("Invalid board slug")
        }
        var url = baseURL.appendingPathComponent("api").appendingPathComponent(resource).appendingPathComponent(slug)
        if let suffix { url.appendPathComponent(suffix) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw FeedbackBasketError.invalidResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let endpoint = components.url else { throw FeedbackBasketError.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw FeedbackBasketError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(CommunityErrorResponse.self, from: data)
            throw FeedbackBasketError.rejected(error?.error ?? "Request failed (\(response.statusCode))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct CommunityErrorResponse: Decodable { let error: String }
public struct FeedbackBasketBoardPage: Decodable, Sendable {
    public let board: FeedbackBasketBoard
    public let feedback: [FeedbackBasketBoardItem]
    public let total: Int
    public let page: Int
    public let limit: Int
    public var hasMore: Bool { page * limit < total }
}
public struct FeedbackBasketBoard: Decodable, Sendable {
    public let name: String
    public let subtitle: String?
    public let logoUrl: String?
    public let primaryColor: String?
    public let footerText: String?
    public let allowAnonymousPosting: Bool
    public let readOnly: Bool
}
public struct FeedbackBasketBoardItem: Decodable, Identifiable, Sendable {
    public let id: String
    public let content: String
    public let fullContent: String
    public let status: String
    public let category: String?
    /// ISO 8601 timestamp, as returned by the public API.
    public let createdAt: String
    public let voteCount: Int
    public let hasVoted: Bool
}
public struct FeedbackBasketVoteResult: Decodable, Sendable {
    public let voted: Bool
    public let voteCount: Int
}
public struct FeedbackBasketBoardSubmission: Decodable, Sendable {
    public let success: Bool
    public let id: String
}
public struct FeedbackBasketPublicRoadmap: Decodable, Sendable {
    public struct Project: Decodable, Sendable { public let name: String; public let slug: String }
    public struct Configuration: Decodable, Sendable {
        public let showDueDates: Bool
        public let showScheduledDates: Bool
        /// The public board's brand color, shared by the board and roadmap.
        public let primaryColor: String
        /// Roadmap statuses the project hides. Their cards are never returned.
        /// `nil` when the server predates contract 3.10.0.
        public let hiddenColumns: [String]?
    }
    public let project: Project
    public let config: Configuration
    public let cards: [FeedbackBasketPublicRoadmapCard]
}
public struct FeedbackBasketPublicRoadmapCard: Decodable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let status: String
    public let dueDate: String?
    public let scheduledDate: String?
    public let position: Int
    public let createdAt: String
}
