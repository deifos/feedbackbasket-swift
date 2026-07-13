// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FeedbackBasket",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "FeedbackBasket", targets: ["FeedbackBasket"]),
    ],
    targets: [
        .target(
            name: "FeedbackBasket",
            path: "Sources/FeedbackBasket",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "FeedbackBasketTests",
            dependencies: ["FeedbackBasket"],
            path: "Tests/FeedbackBasketTests"
        ),
    ]
)
