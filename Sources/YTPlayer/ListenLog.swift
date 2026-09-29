import Foundation

/// Records every track you play (including skips) as one JSON line, so playlists
/// can later be built from what you actually listen to.
///
/// File: ~/Library/Application Support/YTPlayer/listens.jsonl
@MainActor
final class ListenLog {
    struct Entry: Codable {
        let videoId: String
        var title: String
        var artist: String
        var album: String
        let source: String?
        let startedAt: Date
        var listenedSeconds: Double
        var durationSeconds: Double
        var lastPosition: Double
        var completed = false
        var skipped = false
    }

    let fileURL: URL
    private var current: Entry?
    private var lastTick = Date()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YTPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("listens.jsonl")
    }

    func record(_ state: PlayerState) {
        let now = Date()
        defer { lastTick = now }
        guard !state.videoId.isEmpty else { return }

        if state.videoId != current?.videoId {
            flush()
            current = Entry(
                videoId: state.videoId, title: state.title, artist: state.artist, album: state.album,
                source: state.source, startedAt: now, listenedSeconds: 0,
                durationSeconds: state.duration, lastPosition: state.position
            )
            return
        }

        // Metadata can lag the videoId by a tick after a track change, so keep refreshing it.
        current?.title = state.title
        current?.artist = state.artist
        current?.album = state.album
        current?.lastPosition = state.position
        if state.duration > 0 { current?.durationSeconds = state.duration }
        if state.isPlaying {
            current?.listenedSeconds += min(now.timeIntervalSince(lastTick), 2)
        }
    }

    /// Writes the in-progress track. Called on track change and on quit.
    func flush() {
        guard var entry = current, entry.listenedSeconds >= 1 else { current = nil; return }
        current = nil
        entry.completed = entry.durationSeconds > 0 && entry.lastPosition >= entry.durationSeconds - 10
        entry.skipped = !entry.completed && entry.listenedSeconds < 30

        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: fileURL)
        }
    }
}
