import SwiftUI

public extension View {
    /// Presents the native FeedbackBasket form as a sheet.
    func feedbackBasketSheet(
        isPresented: Binding<Bool>,
        context: [String: String] = [:]
    ) -> some View {
        sheet(isPresented: isPresented) {
            FeedbackBasketSheet(context: context)
        }
    }
}

/// A native SwiftUI form for sending feedback.
public struct FeedbackBasketSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var category = FeedbackBasketCategory.improvement
    @State private var message = ""
    @State private var email: String
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sent = false
    @State private var replies: [FeedbackBasketReply] = []
    @State private var threadsToAcknowledge: [FeedbackThreadCredential] = []
    @State private var isLoadingReplies = true

    private let context: [String: String]

    /// Creates a feedback sheet with optional screen or application context.
    public init(context: [String: String] = [:]) {
        self.context = context
        _email = State(initialValue: FeedbackBasket.configuredUser?.email ?? "")
    }

    /// The feedback form content.
    public var body: some View {
        NavigationStack {
            Group {
                if sent {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text("Feedback sent")
                            .font(.title2.bold())
                        Text("Thank you for helping improve the app.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .accessibilityElement(children: .combine)
                } else {
                    Form {
                        if isLoadingReplies || !replies.isEmpty {
                            Section("Team replies") {
                                if isLoadingReplies {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                        Text("Checking for replies…")
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    ForEach(replies) { reply in
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(reply.content)
                                            HStack {
                                                Text(reply.sentByName ?? "FeedbackBasket team")
                                                Spacer()
                                                Text(reply.createdAt, style: .relative)
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        .onAppear { acknowledgeDisplayedReplies() }
                                    }
                                }
                            }
                        }

                        Picker("What is this about?", selection: $category) {
                            ForEach(FeedbackBasketCategory.allCases) { category in
                                Text(category.label).tag(category)
                            }
                        }

                        Section("Your feedback") {
                            TextEditor(text: $message)
                                .frame(minHeight: 140)
                            TextField("Email (optional)", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                        }

                        if let errorMessage {
                            Section {
                                Text(errorMessage).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Share feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if !sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSending ? "Sending…" : "Send") { send() }
                            .disabled(isSending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .task { await loadReplies() }
    }

    private func loadReplies() async {
        let inbox = await FeedbackBasket.loadReplies()
        replies = inbox.replies
        threadsToAcknowledge = inbox.threadsToAcknowledge
        isLoadingReplies = false
    }

    private func acknowledgeDisplayedReplies() {
        guard !threadsToAcknowledge.isEmpty else { return }
        let displayedThreads = threadsToAcknowledge
        threadsToAcknowledge = []
        Task { await FeedbackBasket.markRepliesSeen(in: displayedThreads) }
    }

    private func send() {
        isSending = true
        errorMessage = nil
        Task {
            do {
                try await FeedbackBasket.submitFeedback(
                    message: message,
                    category: category,
                    // Passing an empty string explicitly prevents the configured
                    // user's email from being restored after they clear the field.
                    email: email,
                    context: context
                )
                sent = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }
}
