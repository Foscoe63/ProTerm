// SearchBarView.swift
import SwiftUI

/// Simple search field that highlights matching lines inside a TerminalView.
struct SearchBarView: View {
    @Binding var query: String
    var body: some View {
        HStack {
            TextField("Search in session…", text: $query)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            Button(action: { query = "" }) {
                Image(systemName: "xmark.circle.fill")
            }
        }
        .padding(.horizontal)
    }
}
