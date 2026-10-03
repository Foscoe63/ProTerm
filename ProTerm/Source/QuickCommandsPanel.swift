import SwiftUI
import AppKit

struct QuickCommandsPanel: View {
    @EnvironmentObject var productivityTools: ProductivityTools
    @EnvironmentObject var terminalManager: TerminalManager
    @Binding var isVisible: Bool
    @Binding var panelWidth: CGFloat
    @State private var selectedCategory: String? = nil

    private let contentInset: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            categoryFilters
            Divider()
            commandsList
        }
        .frame(width: panelWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(width: 2)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newWidth = panelWidth + value.translation.width
                            panelWidth = max(200, min(500, newWidth))
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
    }

    private var header: some View {
        HStack {
            Text("Quick Commands")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: { isVisible = false }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, contentInset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// Wrapped chips avoid horizontal ScrollView, which was clipping content on first open.
    private var categoryFilters: some View {
        FlowLayout(spacing: 8) {
            Button("All") {
                selectedCategory = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            ForEach(availableCategories, id: \.self) { category in
                Button(category) {
                    selectedCategory = category
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(contentInset)
    }

    private var commandsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(filteredCommands) { command in
                    QuickCommandRow(command: command)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, contentInset)
            .padding(.vertical, contentInset)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var availableCategories: [String] {
        productivityTools.getAllCategories()
    }

    private var filteredCommands: [ProductivityTools.QuickCommand] {
        if let category = selectedCategory {
            return productivityTools.quickCommands.filter { $0.category == category }
        }
        return productivityTools.quickCommands
    }
}

struct QuickCommandRow: View {
    let command: ProductivityTools.QuickCommand
    @EnvironmentObject var terminalManager: TerminalManager
    @EnvironmentObject var productivityTools: ProductivityTools
    @State private var showingKeywordInput = false
    @State private var keywordInput = ""

    private var safeIconName: String {
        let invalidIcons: [String: String] = [
            "git.branch": "arrow.triangle.branch",
            "package": "shippingbox",
            "cube": "cube.box",
            "command": "terminal"
        ]

        if let migrated = invalidIcons[command.icon] {
            return migrated
        }

        return command.icon
    }

    var body: some View {
        Button(action: {
            if command.requiresKeyword {
                showingKeywordInput = true
            } else {
                executeCommand(command, keyword: nil)
            }
        }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: safeIconName)
                    .foregroundColor(.blue)
                    .frame(width: 20, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(command.name)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if command.requiresKeyword {
                            Image(systemName: "text.cursor")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }

                    if let desc = command.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(command.command)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingKeywordInput) {
            KeywordInputSheet(
                command: command,
                keywordInput: $keywordInput,
                onExecute: { keyword in
                    executeCommand(command, keyword: keyword)
                    showingKeywordInput = false
                    keywordInput = ""
                },
                onCancel: {
                    showingKeywordInput = false
                    keywordInput = ""
                }
            )
        }
    }

    @MainActor
    private func executeCommand(_ command: ProductivityTools.QuickCommand, keyword: String?) {
        guard !terminalManager.sessions.isEmpty else { return }

        let session: TerminalSession
        if let activePTYSession = terminalManager.sessions.first(where: { $0.hasActivePTY }) {
            session = activePTYSession
        } else {
            session = terminalManager.sessions[0]
        }

        var finalCommand = command.command
        if let keyword = keyword, !keyword.isEmpty {
            finalCommand = "\(command.command) \(keyword)".trimmingCharacters(in: .whitespaces)
        }

        if session.hasActivePTY {
            let sanitized = finalCommand.sanitizedTerminalCommand()
            let commandToSend = sanitized.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            session.sendInput(commandToSend)
        } else {
            session.runCommand(finalCommand)
        }

        productivityTools.recordQuickCommandUsage(command.id)
    }
}

// MARK: - Keyword Input Sheet
struct KeywordInputSheet: View {
    let command: ProductivityTools.QuickCommand
    @Binding var keywordInput: String
    let onExecute: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("Enter Input for \(command.name)")
                .font(.title2)
                .fontWeight(.semibold)

            if let placeholder = command.keywordPlaceholder {
                Text("\(command.command) needs: \(placeholder)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            TextField(
                command.keywordPlaceholder ?? "Enter value",
                text: $keywordInput
            )
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit {
                if !keywordInput.trimmingCharacters(in: .whitespaces).isEmpty {
                    onExecute(keywordInput.trimmingCharacters(in: .whitespaces))
                }
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button("Execute") {
                    onExecute(keywordInput.trimmingCharacters(in: .whitespaces))
                }
                .buttonStyle(.borderedProminent)
                .disabled(keywordInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 200)
        .onAppear {
            isFocused = true
        }
    }
}
