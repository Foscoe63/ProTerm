import AppKit
import SwiftUI
import UniformTypeIdentifiers   // ← needed for allowedContentTypes

final class ExportPrintManager {
    static let shared = ExportPrintManager()

    /// Export the given text to a plain‑text file.
    func export(text: String, from window: NSWindow?) {
        let panel = NSSavePanel()
        // macOS 15+ uses `allowedContentTypes` instead of the deprecated
        // `allowedFileTypes`.
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "TerminalExport.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Print the given text using macOS printing system.
    func print(text: String) {
        let view = NSTextView()
        view.string = text
        let printInfo = NSPrintInfo.shared
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.run()
    }
}
