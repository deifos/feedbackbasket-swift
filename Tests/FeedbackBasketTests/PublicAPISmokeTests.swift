import FeedbackBasket
import SwiftUI
import XCTest

final class PublicAPISmokeTests: XCTestCase {
    @MainActor
    func testDocumentedPublicAPICompiles() {
        let user = FeedbackBasketUser(id: "42", email: "person@example.com")
        let sheet = EmptyView().feedbackBasketSheet(
            isPresented: .constant(false),
            context: ["screen": "Settings"]
        )
        let submit: @MainActor (String, FeedbackBasketCategory?, String?, [String: String]) async throws -> Void =
            FeedbackBasket.submitFeedback

        XCTAssertEqual(user.id, "42")
        XCTAssertNotNil(sheet)
        XCTAssertNotNil(submit)
    }
}
