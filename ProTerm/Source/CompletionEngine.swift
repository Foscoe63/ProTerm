import Foundation

/// Tab-completion for the command input: commands, aliases, subcommands from history, and paths.
enum CompletionEngine {
    struct Result: Equatable {
        /// Text before the word being completed (kept as-is when a candidate is inserted).
        let head: String
        /// Full replacements for the last word, best first.
        let candidates: [String]
    }

    private static let directoryOnlyCommands: Set<String> = ["cd", "pushd", "rmdir"]

    static func complete(
        line: String,
        cwd: URL,
        history: [String],
        aliases: [String],
        executables: [String],
        isRemote: Bool
    ) -> Result {
        let split = splitLastWord(line)
        let head = split.head
        let word = split.word
        let tokens = head.split(separator: " ").map(String.init)
        let frequency = historyFrequency(history)

        // First word: command names.
        if tokens.isEmpty && !word.contains("/") {
            guard !word.isEmpty else { return Result(head: head, candidates: []) }
            var pool = Set(aliases)
            pool.formUnion(history.compactMap { $0.split(separator: " ").first.map(String.init) })
            if !isRemote { pool.formUnion(executables) }
            let hits = pool.filter { $0.hasPrefix(word) && $0 != word }
            return Result(head: head, candidates: rank(Array(hits), by: frequency))
        }

        var candidates: [String] = []

        // Remote shells: the local filesystem is irrelevant, so only learn from history.
        // Local: paths, plus subcommands seen in history (e.g. "git ch" -> "checkout").
        if tokens.count == 1, !word.contains("/") {
            let sub = history.compactMap { entry -> String? in
                let parts = entry.split(separator: " ").map(String.init)
                guard parts.count >= 2, parts[0] == tokens[0], parts[1].hasPrefix(word), parts[1] != word,
                      !parts[1].hasPrefix("-") || word.hasPrefix("-") else { return nil }
                return parts[1]
            }
            candidates += rank(Array(Set(sub)), by: frequency)
        }
        if !isRemote {
            let dirsOnly = tokens.first.map { directoryOnlyCommands.contains($0) } ?? false
            candidates += pathCandidates(for: word, cwd: cwd, directoriesOnly: dirsOnly)
        }

        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted }
        return Result(head: head, candidates: candidates)
    }

    // MARK: - Helpers

    /// Splits at the last unescaped space. `head` includes the trailing space.
    static func splitLastWord(_ line: String) -> (head: String, word: String) {
        var lastBreak: String.Index?
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == " ", previous != "\\" { lastBreak = line.index(after: index) }
            previous = ch
            index = line.index(after: index)
        }
        guard let split = lastBreak else { return ("", line) }
        return (String(line[..<split]), String(line[split...]))
    }

    private static func historyFrequency(_ history: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in history {
            let parts = entry.split(separator: " ").map(String.init)
            for part in parts.prefix(2) { counts[part, default: 0] += 1 }
        }
        return counts
    }

    private static func rank(_ items: [String], by frequency: [String: Int]) -> [String] {
        items.sorted {
            let a = frequency[$0, default: 0], b = frequency[$1, default: 0]
            return a != b ? a > b : $0 < $1
        }
    }

    private static func pathCandidates(for word: String, cwd: URL, directoriesOnly: Bool) -> [String] {
        let unescaped = word.replacingOccurrences(of: "\\ ", with: " ")
        let directoryPart: String
        let prefix: String
        if let slash = unescaped.lastIndex(of: "/") {
            directoryPart = String(unescaped[...slash])
            prefix = String(unescaped[unescaped.index(after: slash)...])
        } else {
            directoryPart = ""
            prefix = unescaped
        }

        let base: URL
        if directoryPart.isEmpty {
            base = cwd
        } else if directoryPart.hasPrefix("~") {
            base = URL(fileURLWithPath: (directoryPart as NSString).expandingTildeInPath)
        } else if directoryPart.hasPrefix("/") {
            base = URL(fileURLWithPath: directoryPart)
        } else {
            base = cwd.appendingPathComponent(directoryPart)
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        else { return [] }

        let showHidden = prefix.hasPrefix(".")
        var results: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix), showHidden || !name.hasPrefix(".") else { continue }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if directoriesOnly && !isDir { continue }
            let escaped = name.replacingOccurrences(of: " ", with: "\\ ")
            results.append(directoryPart.replacingOccurrences(of: " ", with: "\\ ") + escaped + (isDir ? "/" : ""))
        }
        return results.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Executables on PATH (cached)

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedExecutables: [String] = []
    nonisolated(unsafe) private static var cacheDate = Date.distantPast

    static func pathExecutables() -> [String] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if Date().timeIntervalSince(cacheDate) < 60 { return cachedExecutables }
        var names = Set<String>()
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: String(dir)) else { continue }
            for item in items where FileManager.default.isExecutableFile(atPath: "\(dir)/\(item)") {
                names.insert(item)
            }
        }
        cachedExecutables = Array(names)
        cacheDate = Date()
        return cachedExecutables
    }
}
