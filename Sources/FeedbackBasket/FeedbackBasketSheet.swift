import SwiftUI

public extension View {
    /// Presents the native FeedbackBasket form as a sheet.
    @MainActor
    func feedbackBasketSheet(
        isPresented: Binding<Bool>,
        context: [String: String] = [:],
        showsUnreadBadge: Bool = true
    ) -> some View {
        modifier(
            FeedbackBasketSheetPresenter(
                isPresented: isPresented,
                context: context,
                showsUnreadBadge: showsUnreadBadge
            )
        )
    }
}

@MainActor
private struct FeedbackBasketSheetPresenter: ViewModifier {
    @ObservedObject private var replyState = FeedbackBasket.replyState

    let isPresented: Binding<Bool>
    let context: [String: String]
    let showsUnreadBadge: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if showsUnreadBadge && replyState.unreadCount > 0 {
                    Text(replyState.unreadCount > 99 ? "99+" : "\(replyState.unreadCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(.red, in: Capsule())
                        .offset(x: 8, y: -8)
                        .allowsHitTesting(false)
                        .accessibilityLabel(
                            "\(replyState.unreadCount) unread feedback replies"
                        )
                }
            }
            .sheet(isPresented: isPresented) {
                FeedbackBasketSheet(context: context)
            }
    }
}

/// A native SwiftUI form for sending feedback and continuing conversations.
public struct FeedbackBasketSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var category = FeedbackBasketCategory.improvement
    @State private var message = ""
    @State private var email: String
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sent = false
    @State private var conversations: [FeedbackConversation] = []
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
                    feedbackForm
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
                            .disabled(
                                isSending ||
                                    message.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                            )
                    }
                }
            }
        }
        .task { await loadReplies() }
    }

    private var feedbackForm: some View {
        Form {
            if isLoadingReplies || !conversations.isEmpty {
                Section("Conversations") {
                    if isLoadingReplies {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking for replies…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(conversations) { conversation in
                            NavigationLink {
                                FeedbackConversationView(conversation: conversation)
                            } label: {
                                FeedbackConversationRow(conversation: conversation)
                            }
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

    private func loadReplies() async {
        let inbox = await FeedbackBasket.loadReplies()
        conversations = inbox.conversations
        isLoadingReplies = false
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

private struct FeedbackConversationRow: View {
    let conversation: FeedbackConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(conversation.originalContent ?? "Feedback conversation")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if conversation.unreadCount > 0 {
                    Text("\(conversation.unreadCount) new")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                }
            }
            if let latest = conversation.messages.last {
                Text(latest.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct FeedbackConversationView: View {
    let conversation: FeedbackConversation

    @State private var messages: [FeedbackBasketMessage]
    @State private var reply = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var didAcknowledge = false

    init(conversation: FeedbackConversation) {
        self.conversation = conversation
        _messages = State(initialValue: conversation.messages)
    }

    var body: some View {
        List {
            if let originalContent = conversation.originalContent {
                Section("Your original feedback") {
                    Text(originalContent)
                }
            }

            Section("Conversation") {
                ForEach(messages) { message in
                    FeedbackMessageBubble(message: message)
                }
            }

            if conversation.visitorRepliesEnabled {
                Section("Reply") {
                    TextEditor(text: $reply)
                        .frame(minHeight: 90)
                    Button(isSending ? "Sending…" : "Send reply") {
                        sendReply()
                    }
                    .disabled(
                        isSending ||
                            reply.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .task { acknowledgeReplies() }
    }

    private func acknowledgeReplies() {
        guard !didAcknowledge, conversation.unreadCount > 0 else { return }
        didAcknowledge = true
        Task {
            await FeedbackBasket.markRepliesSeen(
                in: [conversation.credential],
                unreadCount: conversation.unreadCount
            )
        }
    }

    private func sendReply() {
        let content = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        isSending = true
        errorMessage = nil
        Task {
            do {
                let message = try await FeedbackBasket.sendReply(
                    content,
                    in: conversation
                )
                messages.append(message)
                reply = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }
}

private struct FeedbackMessageBubble: View {
    let message: FeedbackBasketMessage

    var body: some View {
        HStack {
            if message.sender == .visitor { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 5) {
                Text(message.content)
                HStack {
                    Text(
                        message.sender == .visitor
                            ? "You"
                            : message.sentByName ?? "FeedbackBasket team"
                    )
                    Spacer()
                    Text(message.createdAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(
                message.sender == .visitor
                    ? Color.blue.opacity(0.1)
                    : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
            if message.sender == .owner { Spacer(minLength: 36) }
        }
        .listRowSeparator(.hidden)
    }
}
