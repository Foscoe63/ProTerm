// FontPickerView.swift
import SwiftUI

/// Presents a list of monospaced fonts for the user to choose from.
struct FontPickerView: View {
    @Binding var selectedFontName: String
    private let availableFonts = ["Menlo", "SF Mono", "Courier New", "Fira Code", "Monaco"]

    var body: some View {
        List(availableFonts, id: \ .self) { fontName in
            HStack {
                Text(fontName)
                    .font(.custom(fontName, size: 14))
                Spacer()
                if fontName == selectedFontName {
                    Image(systemName: "checkmark")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedFontName = fontName }
        }
        .frame(minWidth: 200, minHeight: 250)
    }
}
