import SwiftUI
import Foundation

struct ChatbotView: View {
    @EnvironmentObject var aiManager: AIManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isProcessing: Bool = false
    @FocusState private var isInputFocused: Bool
    
    struct ChatMessage: Identifiable {
        let id = UUID()
        let text: String
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
                        
                        if isProcessing {
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
                
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(inputText.isEmpty || isProcessing ? .secondary : .blue)
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty || isProcessing)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 600, height: 500)
        .onAppear {
            isInputFocused = true
        }
    }
    
    private func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isProcessing else { return }
        
        let userMessage = ChatMessage(
            text: inputText,
            isUser: true,
            timestamp: Date()
        )
        messages.append(userMessage)
        
        let query = inputText
        inputText = ""
        isProcessing = true
        
        Task {
            do {
                let response = try await getAIResponse(query: query)
                await MainActor.run {
                    let aiMessage = ChatMessage(
                        text: response,
                        isUser: false,
                        timestamp: Date()
                    )
                    messages.append(aiMessage)
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    let errorMessage = ChatMessage(
                        text: "Error: \(error.localizedDescription)",
                        isUser: false,
                        timestamp: Date()
                    )
                    messages.append(errorMessage)
                    isProcessing = false
                }
            }
        }
    }
    
    @MainActor
    private func getAIResponse(query: String) async throws -> String {
        switch aiManager.selectedAI {
        case .siri:
            return try await getSiriResponse(query: query)
        case .lmStudio:
            return try await getLMStudioResponse(query: query)
        }
    }
    
    @MainActor
    private func getSiriResponse(query: String) async throws -> String {
        // Simple text-based assistant that answers terminal-related questions
        let lowerQuery = query.lowercased()
        
        // Handle common terminal command questions
        if lowerQuery.contains("symbolic link") || lowerQuery.contains("symlink") || lowerQuery.contains("ln -s") {
            return "To create a symbolic link, use: `ln -s <target> <link_name>`\n\nExample: `ln -s /path/to/file /path/to/link`\n\nThis creates a symbolic link named 'link' that points to 'file'. The `-s` flag creates a symbolic (soft) link rather than a hard link."
        }
        
        if lowerQuery.contains("list files") || lowerQuery.contains("ls") || lowerQuery.contains("directory") {
            return "To list files in a directory, use: `ls`\n\nCommon options:\n- `ls -l` - Long format with details\n- `ls -a` - Show hidden files\n- `ls -la` - Long format including hidden files\n- `ls -lh` - Human-readable file sizes\n- `ls -lt` - Sort by modification time"
        }
        
        if lowerQuery.contains("find") && (lowerQuery.contains("file") || lowerQuery.contains("search")) {
            return "To find files, use: `find <directory> -name <pattern>`\n\nExamples:\n- `find . -name \"*.txt\"` - Find all .txt files in current directory\n- `find ~ -name \"file.txt\"` - Find file.txt in home directory\n- `find / -type f -name \"*.log\"` - Find all .log files on the system"
        }
        
        if lowerQuery.contains("grep") || lowerQuery.contains("search") && lowerQuery.contains("text") {
            return "To search for text in files, use: `grep <pattern> <file>`\n\nExamples:\n- `grep \"error\" file.txt` - Find lines containing 'error'\n- `grep -r \"pattern\" .` - Recursively search in all files\n- `grep -i \"pattern\" file.txt` - Case-insensitive search\n- `grep -n \"pattern\" file.txt` - Show line numbers"
        }
        
        if lowerQuery.contains("permission") || lowerQuery.contains("chmod") {
            return "To change file permissions, use: `chmod <mode> <file>`\n\nExamples:\n- `chmod 755 file.sh` - Owner: read/write/execute, Others: read/execute\n- `chmod +x file.sh` - Add execute permission\n- `chmod u+w file.txt` - Add write permission for owner\n\nCommon modes: 755 (executable), 644 (readable), 600 (private)"
        }
        
        if lowerQuery.contains("process") || lowerQuery.contains("ps") || lowerQuery.contains("running") {
            return "To view running processes:\n\n- `ps aux` - List all processes\n- `ps aux | grep <name>` - Find specific process\n- `top` - Interactive process monitor\n- `htop` - Enhanced process monitor (if installed)\n- `kill <pid>` - Terminate a process\n- `killall <name>` - Kill all processes by name"
        }
        
        if lowerQuery.contains("network") || lowerQuery.contains("ip") || lowerQuery.contains("ifconfig") {
            return "Network commands:\n\n- `ifconfig` - Show network interfaces\n- `ip addr` - Show IP addresses (Linux-style)\n- `netstat -rn` - Show routing table\n- `ping <host>` - Test connectivity\n- `curl <url>` - Download/request from URL\n- `wget <url>` - Download file (if installed)"
        }
        
        if lowerQuery.contains("git") {
            return "Common Git commands:\n\n- `git status` - Show repository status\n- `git add <file>` - Stage files\n- `git commit -m \"message\"` - Commit changes\n- `git push` - Push to remote\n- `git pull` - Pull from remote\n- `git branch` - List branches\n- `git checkout <branch>` - Switch branch\n- `git log` - View commit history"
        }
        
        if lowerQuery.contains("help") || lowerQuery.contains("how") || lowerQuery.contains("what") {
            return "I can help you with terminal commands! Try asking about:\n\n- File operations (ls, cp, mv, rm)\n- Text search (grep, find)\n- Permissions (chmod, chown)\n- Processes (ps, top, kill)\n- Network (ifconfig, ping, curl)\n- Git commands\n- Symbolic links\n- And more!\n\nJust ask me a question about any terminal command or operation."
        }
        
        // Default helpful response
        return "I'm here to help with terminal commands and macOS operations. You asked: \"\(query)\"\n\nTry asking me about specific commands like:\n- How to create a symbolic link\n- How to find files\n- How to search text in files\n- Git commands\n- File permissions\n- Network commands\n\nOr ask me 'help' for more information!"
    }
    
    @MainActor
    private func getLMStudioResponse(query: String) async throws -> String {
        // Ensure the base URL doesn't already have /v1
        var baseURL = aiManager.lmStudioURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.hasSuffix("/") {
            baseURL = String(baseURL.dropLast())
        }
        if baseURL.hasSuffix("/v1") {
            baseURL = String(baseURL.dropLast(3))
        }
        
        let fullURL = "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: fullURL) else {
            throw NSError(domain: "LMStudioError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid LM Studio URL: \(fullURL)"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": aiManager.lmStudioModel.isEmpty ? "local-model" : aiManager.lmStudioModel,
            "messages": [
                [
                    "role": "user",
                    "content": query
                ]
            ],
            "temperature": 0.7,
            "max_tokens": 1000
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "LMStudioError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "LMStudioError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned status code \(httpResponse.statusCode)"])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "LMStudioError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }
        
        return content
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

