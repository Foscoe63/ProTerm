import AppKit
import Foundation

/// Turns a terminal session's output into exportable files and drives the save panel / share sheet.
@MainActor
enum SessionExporter {
    static let exportNotification = Notification.Name("ProTermExportSession")
    static let shareNotification = Notification.Name("ProTermShareSession")

    // MARK: - Content

    /// Output with ANSI escape sequences removed.
    static func plainText(for session: TerminalSession) -> String {
        let pattern = "\u{1B}(\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|[@-Z\\\\-_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return session.output }
        let range = NSRange(session.output.startIndex..., in: session.output)
        return regex.stringByReplacingMatches(in: session.output, range: range, withTemplate: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    static func data(for session: TerminalSession, format: ProductivityTools.ExportFormat) -> Data? {
        let text = plainText(for: session)
        switch format {
        case .text:
            return text.data(using: .utf8)
        case .html:
            return html(text, title: session.cwd.lastPathComponent).data(using: .utf8)
        case .pdf:
            return pdf(text)
        case .json:
            let payload: [String: Any] = [
                "output": text,
                "workingDirectory": session.cwd.path,
                "exportedAt": ISO8601DateFormatter().string(from: Date())
            ]
            return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        case .csv:
            let rows = text.components(separatedBy: "\n").enumerated().map { index, line in
                "\(index + 1),\"\(line.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return rows.joined(separator: "\n").data(using: .utf8)
        }
    }

    private static func html(_ text: String, title: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let safeTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>ProTerm Session – \(safeTitle)</title>
            <style>
                body { background: #1e1e1e; margin: 0; padding: 24px; }
                pre { background: #000; color: #d4d4d4; padding: 20px; border-radius: 6px;
                      font: 12px/1.4 Menlo, Monaco, monospace; white-space: pre-wrap; word-break: break-word; }
            </style>
        </head>
        <body><pre>\(escaped)</pre></body>
        </html>
        """
    }

    /// Paginated US-Letter PDF of the text in Menlo.
    private static func pdf(_ text: String) -> Data? {
        let pageSize = NSSize(width: 612, height: 792)
        let margin: CGFloat = 36
        let font = NSFont.userFixedPitchFont(ofSize: 9) ?? .monospacedSystemFont(ofSize: 9, weight: .regular)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])

        let info = NSPrintInfo()
        info.paperSize = pageSize
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = pageSize.width - margin * 2
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: pageSize.height))
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.textStorage?.setAttributedString(attributed)
        textView.sizeToFit()

        let output = NSMutableData()
        let operation = NSPrintOperation.pdfOperation(
            with: textView,
            inside: textView.bounds,
            to: output,
            printInfo: info
        )
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run() ? output as Data : nil
    }

    // MARK: - UI

    static func export(_ session: TerminalSession, format: ProductivityTools.ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ProTerm-\(timestamp()).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = data(for: session, format: format) else {
            showError("Could not generate the \(format.rawValue) export.")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Writes a temp .txt file and offers the system share picker anchored to the key window.
    static func share(_ session: TerminalSession) {
        guard let view = NSApp.keyWindow?.contentView,
              let data = data(for: session, format: .text) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProTerm-\(timestamp()).txt")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError(error.localizedDescription)
            return
        }
        let picker = NSSharingServicePicker(items: [url])
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
