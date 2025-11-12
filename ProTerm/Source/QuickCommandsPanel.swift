import SwiftUI
import AppKit

struct QuickCommandsPanel: View {
    @EnvironmentObject var productivityTools: ProductivityTools
    @EnvironmentObject var terminalManager: TerminalManager
    @Binding var isVisible: Bool
    @State private var selectedCategory: ProductivityTools.QuickCommand.QuickCommandCategory? = nil
    
    var body: some View {
        if isVisible {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Quick Commands")
                        .font(.headline)
                    Spacer()
                    Button(action: { isVisible = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // Category filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("All") {
                            selectedCategory = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        ForEach(ProductivityTools.QuickCommand.QuickCommandCategory.allCases, id: \.self) { category in
                            Button(category.rawValue) {
                                selectedCategory = category
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)
                
                Divider()
                
                // Commands list
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredCommands) { command in
                            QuickCommandRow(command: command)
                        }
                    }
                    .padding()
                }
            }
            .frame(width: 250)
            .background(Color(NSColor.windowBackgroundColor))
        }
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
    
    /// Get a valid SF Symbol name, falling back to a default if invalid
    private var safeIconName: String {
        // Known invalid icons that need migration (matches ProductivityTools.migrateIconName)
        let invalidIcons: [String: String] = [
            "git.branch": "arrow.triangle.branch",
            "package": "shippingbox",
            "cube": "cube.box",
            "command": "terminal"
        ]
        
        // If icon is in the invalid list, return the migration
        if let migrated = invalidIcons[command.icon] {
            return migrated
        }
        
        // For other icons, use them as-is (they should be valid after migration)
        // If somehow an invalid icon still exists, fallback based on category
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
            HStack {
                Image(systemName: safeIconName)
                    .foregroundColor(.blue)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(command.name)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        
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
                            .lineLimit(1)
                    }
                    Text(command.command)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            .padding(8)
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
    
    private func executeCommand(_ command: ProductivityTools.QuickCommand, keyword: String?) {
        guard !terminalManager.sessions.isEmpty else { return }
        // Execute in the first session (could be enhanced to use current session)
        let session = terminalManager.sessions[0]
        
        // Build the final command
        var finalCommand = command.command
        if let keyword = keyword, !keyword.isEmpty {
            finalCommand = "\(command.command) \(keyword)".trimmingCharacters(in: .whitespaces)
        }
        
        session.runCommand(finalCommand)
        
        // Update usage stats
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

