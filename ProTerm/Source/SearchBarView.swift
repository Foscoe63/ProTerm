// SearchBarView.swift
import SwiftUI

/// Simple search field that highlights matching lines inside a TerminalView.
struct SearchBarView: View {
    @Binding var query: String
    @State private var useRegex: Bool = false
    @State private var showHistory: Bool = false
    @State private var searchHistory: [String] = []
    @FocusState private var isSearchFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search in session…", text: $query)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search terminal output")
                    .accessibilityHint("Type to search terminal output. Results are highlighted in yellow.")
                    .onChange(of: query) { _, _ in
                        NotificationCenter.default.post(name: .searchInTerminal, object: query)
                        if !query.isEmpty {
                            NotificationCenter.default.post(name: .setSearchRegexMode, object: useRegex)
                        }
                        showHistory = isSearchFocused && !query.isEmpty
                    }
                    .onChange(of: isSearchFocused) { _, focused in
                        showHistory = focused && !query.isEmpty
                        if focused {
                            loadSearchHistory()
                        }
                    }
                Button(action: { 
                    useRegex.toggle()
                    NotificationCenter.default.post(name: .setSearchRegexMode, object: useRegex)
                }) {
                    Image(systemName: useRegex ? "textformat.123" : "textformat")
                        .foregroundColor(useRegex ? .blue : .secondary)
                }
                .help(useRegex ? "Regex mode enabled" : "Click to enable regex mode")
                .accessibilityLabel(useRegex ? "Regex mode enabled" : "Regex mode disabled")
                .accessibilityHint("Toggle regular expression search mode")
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityLabel("Clear search")
                .accessibilityHint("Clear the search query")
            }
            .padding(.horizontal)
            
            if showHistory && !searchHistory.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredHistory, id: \.self) { historyItem in
                            Button(action: {
                                query = historyItem
                                showHistory = false
                                isSearchFocused = false
                                NotificationCenter.default.post(name: .searchInTerminal, object: historyItem)
                            }) {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                    Text(historyItem)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .background(Color(NSColor.controlBackgroundColor))
                            .onHover { hovering in
                                // Visual feedback handled by button style
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(Color(NSColor.windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchInTerminal)) { notification in
            if let newQuery = notification.object as? String, !newQuery.isEmpty {
                if !searchHistory.contains(newQuery) {
                    searchHistory.insert(newQuery, at: 0)
                    if searchHistory.count > 20 {
                        searchHistory.removeLast()
                    }
                    saveSearchHistory()
                }
            }
        }
    }
    
    private var filteredHistory: [String] {
        if query.isEmpty {
            return Array(searchHistory.prefix(10))
        }
        return searchHistory.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(10).map { $0 }
    }
    
    private func loadSearchHistory() {
        if let data = UserDefaults.standard.array(forKey: "ProTermSearchHistory") as? [String] {
            searchHistory = data
        }
    }
    
    private func saveSearchHistory() {
        UserDefaults.standard.set(searchHistory, forKey: "ProTermSearchHistory")
    }
}
