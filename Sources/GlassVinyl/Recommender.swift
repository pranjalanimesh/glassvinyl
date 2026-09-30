import Foundation

/// Fills the For You tab with new songs picked from the listening history.
///
/// Runs Claude Code headless (`claude -p`) on the Claude Code login already on this Mac, so
/// no API key is needed. Claude may only use web search and fetch: it reads Reddit threads,
/// blogs and new-release lists, then returns songs as JSON. Each pick is then looked up on
/// YouTube Music so it can be played. Results are saved next to the listen log.
@MainActor
final class Recommender {
    private let model: PlayerModel
    private let bridge: PlayerBridge
    private let log: ListenLog
    private let cacheURL: URL

    private struct Cache: Codable {
        let date: Date
        let songs: [Recommendation]
    }

    init(model: PlayerModel, bridge: PlayerBridge, log: ListenLog) {
        self.model = model
        self.bridge = bridge
        self.log = log
        cacheURL = log.fileURL.deletingLastPathComponent().appendingPathComponent("recommendations.json")

        if let data = try? Data(contentsOf: cacheURL), let cache = try? Self.decoder.decode(Cache.self, from: data) {
            model.recommendations = cache.songs
            model.recommendationsDate = cache.date
        }
    }

    func refresh() {
        guard !model.isRecommending else { return }
        model.isRecommending = true
        model.recommendationError = nil
        let prompt = makePrompt()

        Task {
            do {
                var picks = try await Self.askClaude(prompt)
                // Show the list right away, then fill in artwork and playable links one by one.
                model.recommendations = picks
                model.recommendationsDate = Date()
                for i in picks.indices {
                    if let hit = try? await search("\(picks[i].title) \(picks[i].artist)") {
                        picks[i].videoId = hit.videoId
                        picks[i].thumb = hit.thumb
                        model.recommendations = picks
                    }
                }
                save(picks)
            } catch {
                model.recommendationError = error.localizedDescription
            }
            model.isRecommending = false
        }
    }

    // MARK: - Prompt

    private func makePrompt() -> String {
        struct Song {
            let title: String
            let artist: String
            var plays = 0, finished = 0, skipped = 0
            var last: Date
        }
        var songs: [String: Song] = [:]
        for entry in log.entries() {
            var song = songs[entry.videoId] ?? Song(title: entry.title, artist: entry.artist, last: entry.startedAt)
            song.plays += 1
            if entry.completed { song.finished += 1 }
            if entry.skipped { song.skipped += 1 }
            song.last = max(song.last, entry.startedAt)
            songs[entry.videoId] = song
        }
        let history = songs.values.sorted { $0.last > $1.last }.prefix(80).map {
            "- \($0.title) — \($0.artist) (played \($0.plays)x, finished \($0.finished), skipped \($0.skipped))"
        }
        let queued = model.queue.prefix(40).map { "- \($0.title) — \($0.artist)" }
        let now = model.state.title.isEmpty ? "nothing" : "\(model.state.title) — \(model.state.artist)"

        return """
        Pick music for one listener. They love discovering songs they haven't heard, so never \
        suggest anything from their history or queue below, and prefer lesser-known tracks and \
        recent releases over obvious hits. Songs they finish are what they like; songs they skip \
        within 30 seconds are what they don't.

        Now playing: \(now)

        Recent YouTube Music listening:
        \(history.isEmpty ? "(none yet)" : history.joined(separator: "\n"))

        Already in their queue:
        \(queued.isEmpty ? "(empty)" : queued.joined(separator: "\n"))

        Search the web for picks real people recommend: Reddit threads (for example "songs like \
        <artist>" on r/ifyoulikeblank, r/IndianMusic, or genre subreddits), music blogs and \
        new-release roundups.

        Return 12 real, released songs that are on YouTube Music. For each give the title, the \
        main artist, a reason under 15 words tied to this listener's taste, and the URL where \
        you found it (empty if none).
        """
    }

    // MARK: - Claude Code

    nonisolated private static let schema = """
    {"type":"object","properties":{"songs":{"type":"array","items":{"type":"object","properties":\
    {"title":{"type":"string"},"artist":{"type":"string"},"reason":{"type":"string"},"source":{"type":"string"}},\
    "required":["title","artist","reason","source"]}}},"required":["songs"]}
    """

    private struct ClaudeError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Runs `claude -p` off the main thread and returns its structured answer.
    nonisolated private static func askClaude(_ prompt: String) async throws -> [Recommendation] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try runClaude(prompt) })
            }
        }
    }

    nonisolated private static func runClaude(_ prompt: String) throws -> [Recommendation] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ClaudeError("Claude Code isn't installed (looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin)")
        }

        // An empty folder, so Claude has no project files to read.
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("GlassVinylRecommender")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = workDir
        process.arguments = [
            "-p", "--output-format", "json",
            "--model", "sonnet",
            "--max-budget-usd", "1",
            "--strict-mcp-config", "--no-session-persistence",
            "--allowedTools", "WebSearch", "WebFetch",
            "--disallowedTools", "Bash", "Edit", "Write", "NotebookEdit",
            "--json-schema", schema,
        ]
        // Apps launched from Finder get a minimal PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try input.fileHandleForWriting.close()

        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
        // Drain stderr in parallel so a full pipe can't stall the process.
        var errorText = ""
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            drained.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        drained.wait()
        timeout.cancel()

        struct Songs: Decodable { let songs: [Recommendation] }
        struct Response: Decodable {
            let is_error: Bool?
            let result: String?
            let structured_output: Songs?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            let detail = errorText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            throw ClaudeError(process.terminationReason == .uncaughtSignal
                ? "Claude took longer than 5 minutes"
                : "Claude Code failed: \(detail.isEmpty ? "exit \(process.terminationStatus)" : String(detail))")
        }
        guard response.is_error != true, let songs = response.structured_output?.songs, !songs.isEmpty else {
            throw ClaudeError(response.result.map { String($0.prefix(200)) } ?? "Claude returned no songs")
        }
        return songs
    }

    // MARK: - YouTube Music lookup

    private func search(_ query: String) async throws -> SearchResult? {
        try await withCheckedThrowingContinuation { continuation in
            bridge.search(query) { result in
                continuation.resume(with: result.map(\.first))
            }
        }
    }

    // MARK: - Cache

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func save(_ songs: [Recommendation]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Cache(date: Date(), songs: songs)) {
            try? data.write(to: cacheURL)
        }
    }
}
