import Foundation

/// A point where the user submitted a command, used to fold that command's output.
struct CommandMarker: Identifiable, Equatable {
    let id = UUID()
    /// UTF-16 offset into the session output at submission time.
    var offset: Int
    let command: String
    let date = Date()
}

/// Folds command output behind clickable headers.
///
/// Folding runs on the raw output *before* ANSI parsing. Headers and placeholders are emitted as OSC 8
/// hyperlinks with a `proterm-fold://<id>` URL, which `ANSIParser` already turns into link attributes.
enum CommandSections {
    static let scheme = "proterm-fold"

    private struct Header {
        let id: UUID
        let lineStart: String.Index
        let afterNewline: String.Index
    }

    static func fold(_ output: String, markers: [CommandMarker], collapsed: Set<UUID>) -> String {
        guard !markers.isEmpty, !output.isEmpty else { return output }
        let utf16Count = output.utf16.count

        // Locate each marker's header line: the line that echoes the command.
        var headers: [Header] = []
        for marker in markers.sorted(by: { $0.offset < $1.offset }) {
            guard marker.offset >= 0, marker.offset <= utf16Count,
                  let at = output.utf16.index(output.utf16.startIndex, offsetBy: marker.offset, limitedBy: output.endIndex)
            else { continue }
            let lineStart: String.Index
            if at == output.startIndex || output[output.index(before: at)] == "\n" {
                lineStart = at  // local shells: the echo arrives after the marker
            } else {
                lineStart = output[..<at].lastIndex(of: "\n").map { output.index(after: $0) } ?? output.startIndex
            }
            guard var newline = output[lineStart...].firstIndex(of: "\n") else { continue }  // still being typed
            // On narrow terminals the echo wraps; a line shorter than the command means it continues below.
            var echo = String(output[lineStart..<newline])
            var wraps = 0
            while echo.count < marker.command.count, wraps < 4 {
                let next = output.index(after: newline)
                guard next < output.endIndex, let end = output[next...].firstIndex(of: "\n") else { break }
                echo += output[next..<end]
                newline = end
                wraps += 1
            }
            let probe = marker.command.split(separator: " ").first.map(String.init) ?? ""
            guard !probe.isEmpty, containsWord(probe, in: Substring(echo)) else { continue }
            if let last = headers.last, last.lineStart >= lineStart { continue }
            headers.append(Header(id: marker.id, lineStart: lineStart, afterNewline: output.index(after: newline)))
        }
        guard !headers.isEmpty else { return output }

        // Only complete lines are ever hidden; the live prompt line stays untouched.
        let completeEnd = output.lastIndex(of: "\n").map { output.index(after: $0) } ?? output.startIndex

        var result = ""
        result.reserveCapacity(output.utf8.count + headers.count * 80)
        var cursor = output.startIndex
        for (index, header) in headers.enumerated() {
            let bodyEnd = index + 1 < headers.count ? headers[index + 1].lineStart : completeEnd
            guard header.afterNewline < bodyEnd else { continue }  // nothing to fold under this header
            let isCollapsed = collapsed.contains(header.id)

            result += output[cursor..<header.lineStart]
            result += link(header.id, isCollapsed ? "▸" : "▾") + " "
            result += output[header.lineStart..<header.afterNewline]
            if isCollapsed {
                let hidden = output[header.afterNewline..<bodyEnd].utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
                result += link(header.id, "    … \(hidden) line\(hidden == 1 ? "" : "s") hidden (click to expand)") + "\n"
                cursor = bodyEnd
            } else {
                cursor = header.afterNewline
            }
        }
        result += output[cursor...]
        return result
    }

    private static func containsWord(_ word: String, in line: Substring) -> Bool {
        let pattern = "(?<![\\w-])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\w-])"
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    static func id(from url: URL) -> UUID? {
        guard url.scheme == scheme, let host = url.host ?? Optional(url.lastPathComponent) else { return nil }
        return UUID(uuidString: host.uppercased())
    }

    private static func link(_ id: UUID, _ text: String) -> String {
        "\u{1B}]8;;\(scheme)://\(id.uuidString)\u{07}\(text)\u{1B}]8;;\u{07}"
    }
}
