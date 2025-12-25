import SwiftUI

struct TerminalInputBar: View {
    @ObservedObject var viewModel: TerminalInputViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text(">")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
            TextField("Enter command", text: $viewModel.commandText, onCommit: {
                viewModel.submit()
            })
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            // Autocorrection and autocapitalization controls are unavailable on macOS SwiftUI.
            // Apply them only on platforms that support these modifiers.
            #if os(iOS) || os(tvOS) || os(visionOS)
            .disableAutocorrection(true)
            .textInputAutocapitalization(.never)
            #endif

            Button("Run") { viewModel.submit() }
                .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Material.regular)
    }
}

#Preview {
    TerminalInputBar(viewModel: TerminalInputViewModel())
}
