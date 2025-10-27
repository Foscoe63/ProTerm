// StatusBarView.swift (updated)
import SwiftUI
import Combine

struct StatusBarView: View {
    @EnvironmentObject var terminalManager: TerminalManager
    @State private var currentDirectory = "~"

    var body: some View {
        HStack {
            Text("Dir: \(currentDirectory)")
                .font(.caption)
                .padding(.leading, 25) // Move directory indicator towards center by 25 pixels
            
            Spacer()
            
            Text("Sessions: \(terminalManager.sessions.count)")
                .font(.caption)
                .padding(.trailing, 25) // Move session counter towards center by 25 pixels
        }
        .padding(.horizontal, 8)
        .onReceive(NotificationCenter.default.publisher(for: .directoryChanged)) { notification in
            if let newDirectory = notification.object as? String {
                currentDirectory = newDirectory
            }
        }
    }
}
