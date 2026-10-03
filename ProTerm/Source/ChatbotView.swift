import SwiftUI
import Foundation

struct ChatbotView: View {
    @EnvironmentObject var aiManager: AIManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isProcessing: Bool = false
    @State private var streamTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool
    
    /// The terminal the chat is about (for working-directory / output context).
    var session: TerminalSession?
    
    struct ChatMessage: Identifiable {
        let id = UUID()
        var text: String
        let isUser: Bool
        let timestamp: Date
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: aiManager.selectedAI.icon)
                        .foregroundColor(.pink)
                    Text("AI Chatbot - \(aiManager.selectedAI.displayName)")
                        .font(.headline)
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: aiManager.selectedAI.icon)
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text("Start a conversation with \(aiManager.selectedAI.displayName)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else {
                            ForEach(messages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        
                        if isProcessing && (messages.last?.text.isEmpty ?? true) {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Thinking...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.leading, 16)
                            .padding(.top, 8)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.last?.text) { _, _ in
                    if let lastMessage = messages.last { proxy.scrollTo(lastMessage.id, anchor: .bottom) }
                }
                .onChange(of: messages.count) { _, _ in
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            // Input area
            HStack(spacing: 12) {
                TextField("Type your message...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .lineLimit(1...5)
                    .disabled(isProcessing)
                    .onSubmit {
                        sendMessage()
                    }
                
                if isProcessing {
                    Button(action: { streamTask?.cancel() }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(inputText.isEmpty ? .secondary : .blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.isEmpty)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 600, height: 500)
        .onAppear {
            isInputFocused = true
        }
        .onDisappear { streamTask?.cancel() }
    }
    
    private func sendMessage() {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isProcessing else { return }
        
        messages.append(ChatMessage(text: query, isUser: true, timestamp: Date()))
        inputText = ""
        isProcessing = true
        
        let history = messages.suffix(20).map {
            AIChatMessage(role: $0.isUser ? .user : .assistant, content: $0.text)
        }
        let system = systemPrompt()
        let reply = ChatMessage(text: "", isUser: false, timestamp: Date())
        messages.append(reply)
        let replyID = reply.id
        
        streamTask = Task {
            defer { Task { @MainActor in isProcessing = false; streamTask = nil } }
            do {
                let provider = try aiManager.makeProvider()
                for try await chunk in provider.stream(messages: history, system: system) {
                    append(chunk, to: replyID)
                }
                if messageText(replyID).isEmpty { append("(empty response)", to: replyID) }
            } catch is CancellationError {
                // Stopped by the user; keep whatever streamed so far.
            } catch {
                if (error as? URLError)?.code == .cancelled { return }
                append(messageText(replyID).isEmpty ? "Error: \(error.localizedDescription)"
                       : "\n\nError: \(error.localizedDescription)", to: replyID)
            }
        }
    }
    
    private func append(_ text: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += text
    }
    
    private func messageText(_ id: UUID) -> String {
        messages.first(where: { $0.id == id })?.text ?? ""
    }
    
    private func systemPrompt() -> String {
        var prompt = "You are an assistant inside ProTerm, a macOS terminal emulator. "
            + "Be concise. Put shell commands in fenced code blocks and mention risks of destructive commands."
        if let session {
            prompt += "\nCurrent directory: \(session.cwd.path)"
            if session.isSSHSession { prompt += "\nThe terminal is connected to a remote host over SSH." }
            if aiManager.includeTerminalContext {
                let tail = SessionExporter.plainText(for: session)
                    .split(separator: "\n", omittingEmptySubsequences: false).suffix(60).joined(separator: "\n")
                prompt += "\n\nRecent terminal output (may contain sensitive data the user chose to share):\n\(tail)"
            }
        }
        return prompt
    }
}

struct ChatBubble: View {
    let message: ChatbotView.ChatMessage
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
            }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.isUser
                            ? Color.blue.opacity(0.2)
                            : Color(NSColor.controlBackgroundColor)
                    )
                    .cornerRadius(12)
                
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: 400, alignment: message.isUser ? .trailing : .leading)
            
            if !message.isUser {
                Spacer()
            }
        }
    }
}

