import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PlaybackItem: Identifiable {
    let id = UUID()
    let url: URL
}

extension Notification.Name {
    static let proTermStartRecording = Notification.Name("ProTermStartRecording")
    static let proTermStopRecording = Notification.Name("ProTermStopRecording")
    static let proTermPlayRecording = Notification.Name("ProTermPlayRecording")
    static let proTermShowRecordings = Notification.Name("ProTermShowRecordings")
}

/// Small "REC" pill shown in the status bar while a session is being recorded.
struct RecordingBadge: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if session.isRecording {
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text("REC").font(.caption2).fontWeight(.bold).foregroundColor(.red)
            }
            .help("This tab is being recorded")
        }
    }
}

/// Plays back an asciicast (.cast) recording with speed and seek controls.
struct PlaybackSheet: View {
    let url: URL
    @EnvironmentObject private var fontManager: FontManager
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var recording: CastFile.Recording?
    @State private var loadError: String?
    @State private var applied = 0  // number of events shown
    @State private var text = ""
    @State private var pendingCR = false
    @State private var isPlaying = false
    @State private var speed = 1.0
    @State private var playTask: Task<Void, Never>?
    @State private var scrubTime = 0.0

    /// Idle gaps longer than this are shortened (like `asciinema play -i`).
    private let idleLimit = 2.0
    private let displayLimit = 100_000

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(recording?.title.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent).font(.headline)
                Spacer()
                Button("Close") { stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            if let loadError {
                Text(loadError).foregroundColor(.red).padding()
                Spacer()
            } else if let recording {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(ANSIParser.parse(String(text.suffix(displayLimit)), baseFont: fontManager.font))
                            .font(fontManager.font)
                            .foregroundColor(themeManager.current.foreground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        Color.clear.frame(height: 1).id("END")
                    }
                    .background(Color.black.opacity(0.85))
                    .onChange(of: applied) { _, _ in proxy.scrollTo("END", anchor: .bottom) }
                }
                Divider()
                controls(for: recording)
            } else {
                ProgressView().padding()
                Spacer()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { load() }
        .onDisappear { stop() }
    }

    private func controls(for recording: CastFile.Recording) -> some View {
        HStack(spacing: 12) {
            Button(action: { isPlaying ? stop() : play() }) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            Button(action: { seek(to: 0) }) { Image(systemName: "backward.end.fill") }
                .help("Restart")
            Slider(value: $scrubTime, in: 0...max(recording.duration, 0.001)) { editing in
                if !editing { seek(to: scrubTime) }
            }
            Text("\(format(scrubTime)) / \(format(recording.duration))")
                .font(.system(.caption, design: .monospaced))
            Picker("Speed", selection: $speed) {
                ForEach([0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
            }
            .labelsHidden()
            .frame(width: 70)
        }
        .padding()
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else {
            loadError = "Could not read \(url.lastPathComponent)."
            return
        }
        guard let parsed = CastFile.parse(data) else {
            loadError = "\(url.lastPathComponent) is not an asciicast v2 file."
            return
        }
        recording = parsed
        play()
    }

    private func play() {
        guard let recording, !isPlaying else { return }
        if applied >= recording.events.count { seek(to: 0) }
        isPlaying = true
        playTask = Task { @MainActor in
            while !Task.isCancelled, applied < recording.events.count {
                let previous = applied == 0 ? 0 : recording.events[applied - 1].time
                let gap = min(recording.events[applied].time - previous, idleLimit)
                try? await Task.sleep(nanoseconds: UInt64(max(gap, 0) / speed * 1_000_000_000))
                if Task.isCancelled { return }
                // Batch events that are due almost together so fast output doesn't re-parse per chunk.
                var batch = 0
                repeat {
                    appendEvent(recording.events[applied])
                    applied += 1
                    batch += 1
                } while applied < recording.events.count && batch < 200
                    && (recording.events[applied].time - recording.events[applied - 1].time) / speed < 0.02
                scrubTime = recording.events[applied - 1].time
            }
            isPlaying = false
        }
    }

    private func stop() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    private func seek(to time: Double) {
        guard let recording else { return }
        let wasPlaying = isPlaying
        stop()
        applied = recording.events.firstIndex { $0.time > time } ?? recording.events.count
        text = CastFile.render(recording.events, count: applied)
        pendingCR = false
        scrubTime = time
        if wasPlaying { play() }
    }

    private func appendEvent(_ event: CastFile.Event) {
        let (normalized, next) = ANSIParser.normalizeControlCharacters(
            event.text.replacingOccurrences(of: "\r\n", with: "\n"), pendingCR: pendingCR)
        pendingCR = next
        text += normalized
    }
}

enum RecordingActions {
    @MainActor
    static func chooseRecording() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = SessionRecorder.directory
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let cast = UTType(filenameExtension: "cast") { panel.allowedContentTypes = [cast, .plainText, .json] }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
