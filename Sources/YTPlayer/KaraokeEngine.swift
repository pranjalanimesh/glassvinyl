import AVFoundation
import Foundation

/// Karaoke: removes the vocals from the current song on this Mac, then plays the
/// instrumental with an adjustable amount of vocal mixed back in.
///
/// Pipeline (tools live in ~/Library/Application Support/YTPlayer/stems/venv):
/// 1. yt-dlp downloads the song's audio.
/// 2. ffmpeg converts it to WAV (the separator can't read YouTube's WebM/Opus).
/// 3. audio-separator runs a Mel-Band RoFormer model on the GPU (Metal), writing a vocal
///    track and a music track.
/// Results are kept in stems/cache/<videoId>/<mode>/, so each song is only separated once.
@MainActor
final class KaraokeEngine: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case removeAll, keepBacking
        var id: Self { self }
        var label: String { self == .removeAll ? "Remove all vocals" : "Keep backing vocals" }
        /// Kim's vocal model is the best at clean removal; the karaoke model takes out only
        /// the lead singer and leaves backing vocals in the music track.
        var modelFile: String {
            self == .removeAll ? "vocals_mel_band_roformer.ckpt" : "mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt"
        }
    }

    enum Phase: Equatable {
        case idle
        case working(String)
        case ready
        case failed(String)
    }

    struct Song: Equatable {
        let videoId: String
        let title: String
        let artist: String
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var song: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var cacheBytes: Int64 = 0
    /// 0 = full karaoke, 1 = the original mix.
    @Published var vocalLevel: Double = 0 {
        didSet { vocalsNode.volume = Float(vocalLevel) }
    }

    nonisolated static let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("YTPlayer/stems", isDirectory: true)
    nonisolated private static let bin = home.appendingPathComponent("venv/bin")
    nonisolated private static let cache = home.appendingPathComponent("cache", isDirectory: true)
    nonisolated private static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        .first(where: FileManager.default.isExecutableFile(atPath:))

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.bin.appendingPathComponent("audio-separator").path)
            && FileManager.default.isExecutableFile(atPath: Self.bin.appendingPathComponent("yt-dlp").path)
            && Self.ffmpeg != nil
    }

    private let bridge: PlayerBridge
    private let model: PlayerModel
    private let engine = AVAudioEngine()
    private let musicNode = AVAudioPlayerNode()
    private let vocalsNode = AVAudioPlayerNode()
    private var musicFile: AVAudioFile?
    private var vocalsFile: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var timer: Timer?
    private var job: Job?

    init(bridge: PlayerBridge, model: PlayerModel) {
        self.bridge = bridge
        self.model = model
        engine.attach(musicNode)
        engine.attach(vocalsNode)
        vocalsNode.volume = 0
        refreshCacheSize()
    }

    // MARK: - Preparing

    /// Makes (or loads) the karaoke track for the song YouTube Music is playing.
    func prepare(mode: Mode) {
        let state = model.state
        guard !state.videoId.isEmpty, isInstalled else { return }
        stop()
        let song = Song(videoId: state.videoId, title: state.title, artist: state.artist)
        self.song = song
        let dir = Self.cache.appendingPathComponent(song.videoId).appendingPathComponent(mode.rawValue)

        if load(from: dir) { return }
        phase = .working("Downloading…")
        let job = Job()
        self.job = job
        Task.detached {
            do {
                try Self.separate(videoId: song.videoId, mode: mode, into: dir, job: job) { stage in
                    Task { @MainActor [weak self] in
                        if self?.job === job { self?.phase = .working(stage) }
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self, self.job === job else { return }
                    self.job = nil
                    self.refreshCacheSize()
                    if !self.load(from: dir) { self.phase = .failed("The separated files couldn't be opened") }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.job === job else { return }
                    self.job = nil
                    self.phase = job.isCancelled ? .idle : .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        job?.cancel()
        job = nil
        phase = .idle
    }

    // MARK: - Playback

    func play() {
        guard let musicFile, phase == .ready else { return }
        if model.state.isPlaying { bridge.togglePlay() }  // pause YouTube Music
        if position >= duration - 0.5 { position = 0 }
        schedule(from: AVAudioFramePosition(position * musicFile.processingFormat.sampleRate))
        do {
            try engine.start()
        } catch {
            phase = .failed("Audio output failed: \(error.localizedDescription)")
            return
        }
        // Both tracks start on the same future host time, so they stay sample-aligned.
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        musicNode.play(at: start)
        vocalsNode.play(at: start)
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        tick()
        musicNode.stop()
        vocalsNode.stop()
        engine.pause()
        timer?.invalidate()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        position = min(max(seconds, 0), duration)
        if wasPlaying { play() }
    }

    /// Stops karaoke and goes back to YouTube Music where it was.
    func stop(resumeYouTube: Bool = false) {
        if isPlaying { pause() }
        position = 0
        if resumeYouTube, !model.state.isPlaying { bridge.togglePlay() }
    }

    func clearCache() {
        stop()
        cancel()
        try? FileManager.default.removeItem(at: Self.cache)
        musicFile = nil
        vocalsFile = nil
        phase = .idle
        song = nil
        refreshCacheSize()
    }

    private func load(from dir: URL) -> Bool {
        guard let music = try? AVAudioFile(forReading: dir.appendingPathComponent("music.flac")),
              let vocals = try? AVAudioFile(forReading: dir.appendingPathComponent("vocals.flac")) else { return false }
        musicFile = music
        vocalsFile = vocals
        engine.connect(musicNode, to: engine.mainMixerNode, format: music.processingFormat)
        engine.connect(vocalsNode, to: engine.mainMixerNode, format: vocals.processingFormat)
        duration = Double(music.length) / music.processingFormat.sampleRate
        position = 0
        phase = .ready
        return true
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let musicFile, let vocalsFile else { return }
        startFrame = min(max(frame, 0), musicFile.length)
        for (node, file) in [(musicNode, musicFile), (vocalsNode, vocalsFile)] {
            node.stop()
            let remaining = file.length - startFrame
            guard remaining > 0 else { continue }
            node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining), at: nil)
        }
    }

    private func tick() {
        guard isPlaying, let musicFile,
              let nodeTime = musicNode.lastRenderTime,
              let playerTime = musicNode.playerTime(forNodeTime: nodeTime), playerTime.sampleTime >= 0 else { return }
        let rate = musicFile.processingFormat.sampleRate
        position = Double(startFrame + playerTime.sampleTime) / rate
        if position >= duration {
            pause()
            position = duration
        }
    }

    private func refreshCacheSize() {
        let files = FileManager.default.enumerator(at: Self.cache, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        cacheBytes = total
    }

    // MARK: - Separation (runs off the main thread)

    /// The running tool, so Cancel can stop it.
    final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private(set) var isCancelled = false

        func run(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            if isCancelled { throw CancellationError() }
            self.process = process
            try process.run()
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            process?.terminate()
            lock.unlock()
        }
    }

    private struct ToolError: LocalizedError {
        let errorDescription: String?
    }

    nonisolated private static func separate(videoId: String, mode: Mode, into dir: URL, job: Job,
                                             progress: @escaping @Sendable (String) -> Void) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        try tool(bin.appendingPathComponent("yt-dlp").path,
                 ["-q", "--no-warnings", "-f", "bestaudio", "--no-playlist",
                  "-o", dir.appendingPathComponent("source.%(ext)s").path,
                  "https://music.youtube.com/watch?v=\(videoId)"], job: job, step: "Download")
        guard let source = try fm.contentsOfDirectory(atPath: dir.path).first(where: { $0.hasPrefix("source.") }) else {
            throw ToolError(errorDescription: "yt-dlp didn't save the song")
        }

        progress("Preparing audio…")
        let wav = dir.appendingPathComponent("input.wav")
        try tool(ffmpeg ?? "ffmpeg", ["-loglevel", "error", "-y", "-i", dir.appendingPathComponent(source).path,
                                      "-ar", "44100", "-ac", "2", wav.path], job: job, step: "Convert")

        progress("Removing vocals…")
        try tool(bin.appendingPathComponent("audio-separator").path,
                 [wav.path, "--model_filename", mode.modelFile,
                  "--model_file_dir", home.appendingPathComponent("models").path,
                  "--output_dir", dir.path, "--output_format", "FLAC"],
                 job: job, step: "Separation") { percent in progress("Removing vocals… \(percent)%") }

        // Outputs are named "input_(vocals)_<model>.flac" and "input_(other|instrumental)_<model>.flac".
        let outputs = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".flac") }
        guard let vocals = outputs.first(where: { $0.lowercased().contains("(vocals)") }),
              let music = outputs.first(where: { $0.lowercased().contains("(other)") || $0.lowercased().contains("(instrumental)") }) else {
            throw ToolError(errorDescription: "The separator didn't produce the expected tracks")
        }
        try fm.moveItem(at: dir.appendingPathComponent(vocals), to: dir.appendingPathComponent("vocals.flac"))
        try fm.moveItem(at: dir.appendingPathComponent(music), to: dir.appendingPathComponent("music.flac"))
        try? fm.removeItem(at: dir.appendingPathComponent(source))
        try? fm.removeItem(at: wav)
    }

    /// Runs a command-line tool and waits. `onPercent` receives progress-bar percentages
    /// read from its output.
    nonisolated private static func tool(_ path: String, _ arguments: [String], job: Job, step: String,
                                         onPercent: ((Int) -> Void)? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = errors

        let tail = OutputTail()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            tail.append(text)
            if let onPercent, let match = text.matches(of: #/(\d{1,3})%/#).last, let value = Int(match.1) {
                onPercent(min(value, 100))
            }
        }
        try job.run(process)
        process.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil

        if job.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let detail = tail.lastLine ?? "exit \(process.terminationStatus)"
            throw ToolError(errorDescription: "\(step) failed: \(detail)")
        }
    }

    /// The last few hundred characters a tool printed, for error messages.
    private final class OutputTail: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func append(_ more: String) {
            lock.lock()
            text = String((text + more).suffix(600))
            lock.unlock()
        }

        var lastLine: String? {
            lock.lock()
            defer { lock.unlock() }
            return text.split(separator: "\n").last.map(String.init)
        }
    }
}
