import SwiftUI

struct TerminalSearchPanel: View {
    @ObservedObject var viewModel: TerminalSearchViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            TextField("Find…", text: $viewModel.query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
            Toggle("Regex", isOn: $viewModel.isRegex)
            Toggle("Match Case", isOn: $viewModel.matchCase)
            Button("Prev") { viewModel.findPrevious() }
            Button("Next") { viewModel.findNext() }
        }
        .padding(8)
        .background(Material.thin)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    TerminalSearchPanel(viewModel: TerminalSearchViewModel())
        .padding()
}
