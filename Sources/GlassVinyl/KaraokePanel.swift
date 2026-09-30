import SwiftUI

/// Settings → Karaoke: make a karaoke track of the current song and play it with a
/// vocal level control.
struct KaraokePanel: View {
    @ObservedObject var engine: KaraokeEngine
    @ObservedObject var model: PlayerModel

    @AppStorage(SettingKey.karaokeMode) private var mode = KaraokeEngine.Mode.removeAll
    @State private var scrubbing: Double?

    /// The YouTube Music song differs from the one loaded here.
    private var isDifferentSong: Bool {
        !model.state.videoId.isEmpty && model.state.videoId != engine.song?.videoId
    }

    var body: some View {
        if !engine.isInstalled {
            Section("Setup") {
                Text("Karaoke removes vocals on this Mac with Mel-Band RoFormer. It needs a one-time install of about 1 GB (a Python environment with audio-separator and yt-dlp) in ~/Library/Application Support/GlassVinyl/stems, plus ffmpeg (brew install ffmpeg). The vocal model, about 900 MB, downloads the first time you use it.")
                    .foregroundStyle(.secondary)
                HStack {
                    if let status = engine.installStatus {
                        ProgressView().controlSize(.small)
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Install") { engine.install() }
                        .disabled(engine.installStatus != nil)
                }
                if case .failed(let message) = engine.phase {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        } else {
            Section("Song") {
                Picker("Vocals", selection: $mode) {
                    ForEach(KaraokeEngine.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                songRow
            }
            if engine.phase == .ready, let song = engine.song {
                Section("Now singing: \(song.title)") { transport }
            }
            Section {
                HStack {
                    Text("Saved karaoke tracks: \(ByteCountFormatter.string(fromByteCount: engine.cacheBytes, countStyle: .file))")
                    Spacer()
                    Button("Clear") { engine.clearCache() }
                        .disabled(engine.cacheBytes == 0)
                }
                Text("Runs on this Mac: the song is downloaded with yt-dlp (against YouTube's terms), then Mel-Band RoFormer removes the vocals on the GPU. About a minute per song, once; after that it opens instantly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Song

    @ViewBuilder private var songRow: some View {
        let state = model.state
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title.isEmpty ? "Nothing playing" : state.title).lineLimit(1)
                Text(state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            switch engine.phase {
            case .working(let stage):
                ProgressView().controlSize(.small)
                Text(stage).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("Cancel", action: engine.cancel)
            case .ready where !isDifferentSong:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            default:
                Button("Make karaoke track") { engine.prepare(mode: mode) }
                    .disabled(state.videoId.isEmpty)
            }
        }
        if case .failed(let message) = engine.phase {
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }

    // MARK: - Playback

    private var transport: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    engine.isPlaying ? engine.pause() : engine.play()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                VStack(spacing: 2) {
                    Slider(value: Binding(get: { scrubbing ?? engine.position },
                                          set: { scrubbing = $0 }),
                           in: 0...max(engine.duration, 1)) { editing in
                        if !editing, let target = scrubbing {
                            engine.seek(to: target)
                            scrubbing = nil
                        }
                    }
                    .labelsHidden()  // otherwise the form reserves a label column
                    HStack {
                        Text(Self.time(scrubbing ?? engine.position))
                        Spacer()
                        Text(Self.time(engine.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Image(systemName: "mic.slash").foregroundStyle(.secondary)
                Slider(value: $engine.vocalLevel, in: 0...1).labelsHidden()
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                Text("\(Int(engine.vocalLevel * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .help("Vocals: 0% is full karaoke, 100% is the original song")

            HStack {
                Spacer()
                Button("Back to YouTube Music") { engine.stop(resumeYouTube: true) }
            }
        }
    }

    private static func time(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
