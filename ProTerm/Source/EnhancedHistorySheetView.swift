import SwiftUI

/// Command history sheet with search and per-command statistics.
/// Lives in its own file so `TerminalNotificationModifier` can present it
/// (it was `private` to TerminalView.swift and therefore unreachable from there).
struct EnhancedHistorySheetView: View {
  @ObservedObject var session: TerminalSession
  let onPick: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var searchText: String = ""
  @State private var showStatistics: Bool = false

  private var filteredCommands: [String] {
    let reversed = session.commandHistory.reversed()
    if searchText.isEmpty {
      return Array(reversed)
    }
    return reversed.filter { $0.localizedCaseInsensitiveContains(searchText) }
  }

  private var commandStats: [String: Int] {
    var stats: [String: Int] = [:]
    for cmd in session.commandHistory {
      let baseCmd = cmd.components(separatedBy: " ").first ?? cmd
      stats[baseCmd, default: 0] += 1
    }
    return stats
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        searchBar
        Divider()
        if showStatistics {
          statisticsList
        } else {
          commandList
        }
      }
      .navigationTitle("Command History")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button(action: { showStatistics.toggle() }) {
            Image(systemName: showStatistics ? "chart.bar.fill" : "chart.bar")
          }
        }
      }
    }
    .frame(width: 600, height: 400)
  }

  private var searchBar: some View {
    HStack {
      Image(systemName: "magnifyingglass")
        .foregroundColor(.secondary)
      TextField("Search history...", text: $searchText)
      if !searchText.isEmpty {
        Button(action: { searchText = "" }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding()
  }

  private var statisticsList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text("Command Statistics")
          .font(.headline)
          .padding()

        ForEach(Array(commandStats.sorted(by: { $0.value > $1.value }).prefix(10)), id: \.key) { cmd, count in
          HStack {
            Text(cmd)
              .font(.system(.body, design: .monospaced))
            Spacer()
            Text("\(count)")
              .foregroundColor(.secondary)
          }
          .padding(.horizontal)
        }
      }
    }
  }

  @ViewBuilder
  private var commandList: some View {
    if filteredCommands.isEmpty {
      VStack {
        Spacer()
        Text("No commands found")
          .foregroundColor(.secondary)
        Spacer()
      }
    } else {
      List(filteredCommands, id: \.self) { cmd in
        HStack {
          Text(cmd)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
          Spacer()
          Button("Use") {
            onPick(cmd)
            dismiss()
          }
          .buttonStyle(.borderedProminent)
        }
        .contentShape(Rectangle())
        .onTapGesture {
          onPick(cmd)
          dismiss()
        }
      }
      .listStyle(.plain)
    }
  }
}