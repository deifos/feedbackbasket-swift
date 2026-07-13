# FeedbackBasket Swift SDK

Collect contextual feedback inside iOS applications and send it to the same
FeedbackBasket dashboard used by your web projects.

The SDK supports iOS 16 and later and includes:

- A native SwiftUI feedback sheet
- In-app team replies in the same feedback sheet
- Programmatic feedback submission
- Automatic app and device context
- A lightweight connection heartbeat for dashboard verification
- A bundled Apple privacy manifest

Crash reporting, analytics, session recording, and automatic error capture are
not included.

## Installation

In Xcode, open **File → Add Package Dependencies** and enter:

```text
https://github.com/deifos/feedbackbasket-swift.git
```

Add the `FeedbackBasket` product to the main iOS application target. Use version
`0.2.0` or later for in-app team replies.

For a Swift package manifest, add:

```swift
.package(
    url: "https://github.com/deifos/feedbackbasket-swift.git",
    from: "0.2.0"
)
```

## Get a mobile project key

Open your project at [feedbackbasket.com](https://feedbackbasket.com), go to
**Feedback setup → Mobile app**, and enable mobile feedback. The dashboard
provides a public key beginning with `fb_mobile_`.

The mobile project key identifies the FeedbackBasket project. It is designed to
be included in an application and is not a private API secret.

## Configure the SDK

Configure FeedbackBasket once during application startup:

```swift
import FeedbackBasket
import SwiftUI

@main
struct ExampleApp: App {
    init() {
        FeedbackBasket.configure(
            projectKey: "fb_mobile_your_project_key"
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

If the application already has an authenticated user, you can attach their
existing stable ID and email:

```swift
FeedbackBasket.configure(
    projectKey: "fb_mobile_your_project_key",
    user: FeedbackBasketUser(
        id: currentUser.id,
        email: currentUser.email
    )
)
```

Do not invent identity information or collect additional personal information
solely for FeedbackBasket.

## Present the SwiftUI feedback sheet

```swift
import FeedbackBasket
import SwiftUI

struct SettingsView: View {
    @State private var showingFeedback = false

    var body: some View {
        Button("Send feedback") {
            showingFeedback = true
        }
        .feedbackBasketSheet(
            isPresented: $showingFeedback,
            context: ["screen": "Settings"]
        )
    }
}
```

The standard form includes an optional email field. A configured email is
prefilled, but the user can clear it to submit without an email address.

## Receive team replies

No additional host-app code is required. After a dashboard user sends an
in-app reply, the SDK shows it under **Team replies** the next time the native
feedback sheet opens. Reply checks are non-blocking, so the form still opens
normally when the device is offline or FeedbackBasket is temporarily
unavailable.

Each native submission receives a per-thread reply credential. The SDK stores
that credential in the app Keychain, uses it only in authenticated reply
requests, and marks replies seen after displaying them. Credentials are never
placed in URLs or logs.

## Submit feedback programmatically

```swift
try await FeedbackBasket.submitFeedback(
    message: "The save button is not responding",
    category: .bug,
    context: ["screen": "Editor"]
)
```

Available categories are:

- `.bug`
- `.featureRequest`
- `.improvement`
- `.question`

`submitFeedback` throws `FeedbackBasketError.notConfigured` when configuration
is missing, `FeedbackBasketError.rejected` when the server returns a readable
error, and `FeedbackBasketError.invalidResponse` for an unexpected response.

## Context and privacy

Feedback submissions automatically include the app version, build number,
bundle ID, iOS version, device family, locale, and SDK version when available.
Context supplied during configuration or submission is merged with those
values. Only attach non-sensitive context such as the current screen or feature.
Never send passwords, authentication tokens, payment information, private form
contents, or other secrets.

Configuration schedules a connection heartbeat. At most once every 24 hours,
the SDK sends the project key, bundle ID, app version/build, SDK version, and a
random Keychain-backed installation identifier. The last successful heartbeat
time is stored in app-only `UserDefaults` to throttle connections.

Per-submission reply credentials are stored in the app Keychain so the native
sheet can retrieve and acknowledge team replies. They are not shared with the
host app or stored in `UserDefaults`.

The package bundles `PrivacyInfo.xcprivacy` for its own behavior. Applications
using the SDK remain responsible for reviewing their privacy policy, App Store
privacy answers, and any additional user or context data they provide.

FeedbackBasket does not use SDK data for cross-app tracking.

## Bundle ID validation

The FeedbackBasket mobile settings can optionally allow specific iOS bundle
IDs. When configured, SDK submissions from other bundle IDs are rejected.
Bundle IDs reduce accidental misuse but are not authentication secrets.

## Staging and testing

Do not submit test feedback to a production project without approval. Without a
staging key, verify package resolution, compilation, automated tests, and form
presentation only.

When a staging server and project key are available:

```swift
FeedbackBasket.configure(
    projectKey: "fb_mobile_staging_key",
    baseURL: URL(string: "https://staging.example.com")!
)
```

The production base URL defaults to `https://feedbackbasket.com`.

## Requirements

- iOS 16 or later
- Swift 5.9 or later
- Xcode with Swift Package Manager support

## Development

Build for an iOS Simulator:

```bash
xcodebuild \
  -scheme FeedbackBasket \
  -destination 'generic/platform=iOS Simulator' \
  clean build
```

Run the test suite with an installed simulator:

```bash
xcodebuild \
  -scheme FeedbackBasket \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

## Support

- Product: [feedbackbasket.com](https://feedbackbasket.com)
- Issues: [GitHub Issues](https://github.com/deifos/feedbackbasket-swift/issues)

## License

FeedbackBasket Swift SDK is available under the MIT License. See [LICENSE](LICENSE).
