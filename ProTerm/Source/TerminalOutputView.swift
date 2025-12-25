import SwiftUI

/// Read‑only terminal output surface. This initial scaffold intentionally contains
/// no behavior beyond rendering a simple text placeholder. In a follow‑up step,
/// this view will host attributed text rendering, selection, and inline elements
/// (links, images, OSC 8/133), migrated out of TerminalView.
struct TerminalOutputView: View {
    let placeholder: String

    init(placeholder: String = "Terminal Output") {
        self.placeholder = placeholder
    }

    var body: some View {
        ScrollView {
            Text(placeholder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color.black.opacity(0.9))
    }
}

#Preview {
    TerminalOutputView()
}
