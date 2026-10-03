import Foundation

/// asciicast v2 reading and writing (https://docs.asciinema.org/manual/asciicast/v2/).
/// Only output events ("o") are recorded: typed input is never stored, so passwords stay out of files.
enum CastFile {
    struct Event: Equatable {
        let time: Double
        let text: String
    }

    struct Recording {
        var width: Int
        var height: Int
        var title: String?
        var events: [Event]
        var duration: Double { events.last?.time ?? 0 }
    }

    static func headerLine(columns: Int, rows: Int, title: String, timestamp: Date) -> String {
        let header: [String: Any] = [
            "version": 2, "width": columns, "height": rows,
            "timestamp": Int(timestamp.timeIntervalSince1970), "title": title,
            "env": ["TERM": "xterm-256color"]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func eventLine(time: Double, text: String) -> String {
        // JSONSerialization needs a container; encode the string alone, then splice it in.
        let escaped = (try? JSONSerialization.data(withJSONObject: [text], options: []))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        let inner = String(escaped.dropFirst().dropLast())  // "...."
        return "[" + String(format: "%.6f", time) + ",\"o\"," + inner + "]"
    }

    static func parse(_ data: Data) -> Recording? {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first,
              let headerData = first.data(using: .utf8),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              (header["version"] as? Int) == 2 else { return nil }
        var recording = Recording(
            width: header["width"] as? Int ?? 80, height: header["height"] as? Int ?? 24,
            title: header["title"] as? String, events: [])
        var lastTime = 0.0
        for line in lines.dropFirst() {
            guard let lineData = line.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: lineData) as? [Any],
                  array.count >= 3, let time = (array[0] as? NSNumber)?.doubleValue,
                  (array[1] as? String) == "o", let text = array[2] as? String else { continue }
            lastTime = max(lastTime, time)
            recording.events.append(Event(time: lastTime, text: text))
        }
        return recording
    }

    /// Rebuilds scrollback text from the first `count` events using the same line normalization as live output.
    static func render(_ events: [Event], count: Int) -> String {
        var text = ""
        var pendingCR = false
        for event in events.prefix(count) {
            let (normalized, next) = ANSIParser.normalizeControlCharacters(
                event.text.replacingOccurrences(of: "\r\n", with: "\n"), pendingCR: pendingCR)
            pendingCR = next
            text += normalized
        }
        return text
    }
}

/// Appends timestamped output chunks to a .cast file as they arrive.
@MainActor
final class SessionRecorder {
    let url: URL
    private let handle: FileHandle
    private let startedAt = Date()
    private var bytesWritten = 0
    /// Safety valve so a forgotten recording can't fill the disk (200 MB).
    private let maxBytes = 200 * 1024 * 1024

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ProTerm/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init?(columns: Int, rows: Int, title: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeTitle = title.replacingOccurrences(of: "/", with: "-").prefix(40)
        url = Self.directory.appendingPathComponent("\(formatter.string(from: startedAt))-\(safeTitle).cast")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        write(CastFile.headerLine(columns: columns, rows: rows, title: title, timestamp: startedAt) + "\n")
    }

    /// Returns false once the size cap is hit (caller should stop the recording).
    @discardableResult
    func record(_ text: String) -> Bool {
        guard bytesWritten < maxBytes else { return false }
        write(CastFile.eventLine(time: Date().timeIntervalSince(startedAt), text: text) + "\n")
        return true
    }

    func stop() {
        try? handle.close()
    }

    private func write(_ line: String) {
        let data = Data(line.utf8)
        bytesWritten += data.count
        try? handle.write(contentsOf: data)
    }
}
