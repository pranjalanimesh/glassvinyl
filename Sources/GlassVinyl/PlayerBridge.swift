import AppKit

/// Drives the YouTube Music tab already open in Brave.
///
/// AppleScript's `execute javascript` runs in an isolated world that can't see the page's
/// own objects, so each call injects Resources/bridge.js into the page as a <script> and
/// reads the answer back through a DOM event.
/// Needs Brave > View > Developer > Allow JavaScript from Apple Events.
@MainActor
final class PlayerBridge {
    static let braveID = "com.brave.Browser"
    static let musicAppID = "com.brave.Browser.app.cinhimbnkkaeohfgghhklpknlkffjgod"

    var onPoll: ((PlayerState, UpNext?) -> Void)?
    /// Why nothing can be shown (Brave closed, no tab, permission off), or nil when all is well.
    var onProblem: ((String?) -> Void)?
    /// Include the Up Next list in each poll. Only on while the queue is on screen.
    var wantsQueue = false

    private let bridgeSource: String
    /// "tab id X of window id Y", cached so each call is a single Apple Event.
    private var tabRef: String?
    private var isPolling = false
    private var timer: Timer?

    init() {
        bridgeSource = Bundle.main.url(forResource: "bridge", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    // MARK: - Playback

    func togglePlay() { fire("__ytp.toggle()") }
    func toggleLike() { fire("__ytp.toggleLike()") }
    func next() { fire("__ytp.next()") }
    func previous() { fire("__ytp.previous()") }
    func seek(to seconds: Double) { fire("__ytp.seek(\(seconds))") }

    // MARK: - Queue

    /// Adds songs right after the current one (`next`) or at the end of Up Next.
    /// Returns how many were added.
    func addToQueue(_ videoIds: [String], next: Bool, completion: @escaping (Result<Int, Error>) -> Void) {
        start({ id in "__ytp.add(\(literal(id)), \(array(videoIds)), \(next))" }) { [weak self] (result: Result<Int, Error>) in
            completion(result)
            self?.poll()
        }
    }
    func playNow(_ videoId: String) { fire("__ytp.playNow(\(literal(videoId)))") }
    func jump(to index: Int) { fire("__ytp.jump(\(index))") }
    func playAutoplay(at index: Int, videoId: String) { fire("__ytp.playAutoplay(\(index), \(literal(videoId)))") }
    func remove(at index: Int, videoId: String) { fire("__ytp.remove(\(index), \(literal(videoId)))") }
    /// `to` is the song's final position in the full queue.
    func move(from: Int, to: Int, videoId: String) { fire("__ytp.move(\(from), \(to), \(literal(videoId)))") }

    // MARK: - Playlists

    func playPlaylist(_ playlistId: String, shuffle: Bool) {
        fire("__ytp.playPlaylist(\(literal(playlistId)), \(shuffle))")
    }

    /// Plays a playlist starting at one of its songs.
    func playFromPlaylist(_ playlistId: String, videoId: String) {
        fire("__ytp.playFromPlaylist(\(literal(playlistId)), \(literal(videoId)))")
    }

    // MARK: - Search

    func search(_ query: String, completion: @escaping (Result<[SearchResult], Error>) -> Void) {
        start({ id in "__ytp.search(\(literal(id)), \(literal(query)))" }, completion: completion)
    }

    /// Async form of `start`: `expression` receives the call id as a JavaScript literal.
    func value<T: Decodable>(_ expression: @escaping (String) -> String) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            start({ id in expression(Self.literal(id)) }) { (result: Result<T, Error>) in
                continuation.resume(with: result)
            }
        }
    }

    /// Starts an async page call under a fresh id, then waits for its result.
    private func start<T: Decodable>(_ expression: (String) -> String,
                                     completion: @escaping (Result<T, Error>) -> Void) {
        let id = UUID().uuidString
        call(expression(id)) { [weak self] result in
            if case .failure(let error) = result { return completion(.failure(error)) }
            self?.awaitResult(id, attemptsLeft: 240, completion: completion)  // about a minute
        }
    }

    /// `{ value }` or `{ error }` once settled; `null` while still running.
    private struct Pending<T: Decodable>: Decodable {
        let value: T?
        let error: String?
    }

    private func awaitResult<T: Decodable>(_ id: String, attemptsLeft: Int,
                                           completion: @escaping (Result<T, Error>) -> Void) {
        guard attemptsLeft > 0 else { return completion(.failure(BridgeError("YouTube Music didn't answer in time"))) }
        call("__ytp.result(\(literal(id)))") { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                guard let pending = try? JSONDecoder().decode(Pending<T>.self, from: Data(json.utf8)) else {
                    // Still running.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self?.awaitResult(id, attemptsLeft: attemptsLeft - 1, completion: completion)
                    }
                    return
                }
                if let error = pending.error { return completion(.failure(BridgeError(error))) }
                guard let value = pending.value else { return completion(.failure(BridgeError("Empty answer"))) }
                completion(.success(value))
            }
        }
    }

    /// Brings the YouTube Music web app window to the front.
    func showWindow() {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: Self.musicAppID)
                ?? ws.urlForApplication(withBundleIdentifier: Self.braveID) else { return }
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Polling

    private struct PollResponse: Decodable {
        let state: PlayerState
        let queue: [QueueItem]?
        let autoplay: [QueueItem]?
    }

    func poll() {
        guard !isPolling else { return }
        isPolling = true
        call("__ytp.poll(\(wantsQueue), \(EQSettings.current.javaScript))") { [weak self] result in
            guard let self else { return }
            self.isPolling = false
            switch result {
            case .success(let json):
                guard let response = try? JSONDecoder().decode(PollResponse.self, from: Data(json.utf8)) else { return }
                self.onProblem?(nil)
                let upNext = response.queue.map { UpNext(queue: $0, autoplay: response.autoplay ?? []) }
                self.onPoll?(response.state, upNext)
            case .failure(let error):
                self.onProblem?(error.localizedDescription)
                self.onPoll?(PlayerState(), nil)
            }
        }
    }

    // MARK: - Equalizer

    private var lastEQSent: String?
    private var eqUpdateScheduled = false

    /// Sends the EQ settings to the page now instead of on the next poll, so slider moves
    /// are heard straight away. Coalesces bursts of changes into one call.
    func applyEQSoon() {
        guard !eqUpdateScheduled else { return }
        eqUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.eqUpdateScheduled = false
            let eq = EQSettings.current.javaScript
            guard eq != self.lastEQSent else { return }
            self.lastEQSent = eq
            self.call("__ytp.setEq(\(eq))") { _ in }
        }
    }

    /// Runs an action, then refreshes right away so the UI doesn't wait for the next tick.
    private func fire(_ expression: String) {
        call(expression) { [weak self] _ in self?.poll() }
    }

    // MARK: - Transport

    struct BridgeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Evaluates `expression` in the page and returns its JSON result.
    /// AppleScript runs off the main thread so a slow Brave never stalls the widget.
    private func call(_ expression: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard !bridgeSource.isEmpty else {
            return completion(.failure(BridgeError("bridge.js missing. Build with ./build.sh")))
        }
        // `tell application` would launch Brave if it isn't running, so check first.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.braveID).isEmpty else {
            tabRef = nil
            return completion(.failure(BridgeError("Brave isn't running")))
        }
        let cachedRef = tabRef
        let script = BraveScript.pageScript(bridge: bridgeSource, expression: expression)
        BraveScript.queue.async {
            let outcome: (ref: String?, result: Result<String, Error>)
            switch cachedRef.map({ .success($0) }) ?? BraveScript.findMusicTab() {
            case .failure(let error):
                outcome = (nil, .failure(error))
            case .success(nil):
                outcome = (nil, .failure(BridgeError("Open YouTube Music in Brave")))
            case .success(let ref?):
                let result = BraveScript.execute(BraveScript.tell(ref, script))
                // On failure the tab may be gone; search again next time.
                if case .failure = result { outcome = (nil, result) } else { outcome = (ref, result) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.tabRef = outcome.ref
                    completion(outcome.result)
                }
            }
        }
    }

    private func literal(_ string: String) -> String {
        Self.literal(string)
    }

    /// A Swift string as a JavaScript string literal.
    nonisolated static func literal(_ string: String) -> String {
        BraveScript.jsLiteral(string)
    }

    private func array(_ strings: [String]) -> String {
        "[" + strings.map(literal).joined(separator: ",") + "]"
    }
}

/// AppleScript plumbing. Everything here runs on `queue`, one script at a time.
private enum BraveScript {
    static let queue = DispatchQueue(label: "glassvinyl.applescript")

    static func jsLiteral(_ string: String) -> String {
        let data = try? JSONEncoder().encode(string)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "''"
    }

    /// Wraps a main-world expression in an isolated-world script that injects it and
    /// returns its JSON result.
    static func pageScript(bridge: String, expression: String) -> String {
        let main = """
        \(bridge)
        ;(() => {
          let r;
          try { r = \(expression); } catch (e) { r = { error: String(e) }; }
          document.dispatchEvent(new CustomEvent('ytp-out', { detail: JSON.stringify(r) ?? 'null' }));
        })();
        """
        return """
        (() => {
          let out = null;
          const onOut = (e) => { out = e.detail; };
          document.addEventListener('ytp-out', onOut);
          try {
            if (!window.__ytpPolicy) {
              const make = (name) => trustedTypes.createPolicy(name, { createScript: (s) => s });
              try { window.__ytpPolicy = make('ytp-bridge'); } catch (e) { window.__ytpPolicy = make('ytp-bridge-' + Date.now()); }
            }
            const s = document.createElement('script');
            s.nonce = document.querySelector('script[nonce]')?.nonce || '';
            s.textContent = window.__ytpPolicy.createScript(\(jsLiteral(main)));
            document.documentElement.appendChild(s);
            s.remove();
          } finally {
            document.removeEventListener('ytp-out', onOut);
          }
          return out;
        })()
        """
    }

    static func tell(_ tabRef: String, _ js: String) -> String {
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        with timeout of 3 seconds
          tell application "Brave Browser" to execute \(tabRef) javascript "\(escaped)"
        end timeout
        """
    }

    /// "tab id X of window id Y" for the first music.youtube.com tab, or nil if there is none.
    static func findMusicTab() -> Result<String?, Error> {
        execute(findTabScript).map { $0.isEmpty ? nil : $0 }
    }

    static func execute(_ source: String) -> Result<String, Error> {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message: String
            switch error[NSAppleScript.errorNumber] as? Int {
            case 12: message = "In Brave: View > Developer > Allow JavaScript from Apple Events"
            case -1743: message = "Allow GlassVinyl to control Brave in System Settings > Privacy > Automation"
            default: message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
            }
            return .failure(PlayerBridge.BridgeError(message))
        }
        return .success(result?.stringValue ?? "null")
    }

    private static let findTabScript = """
    with timeout of 3 seconds
      tell application "Brave Browser"
        repeat with w in windows
          set urls to URL of tabs of w
          repeat with i from 1 to count of urls
            if item i of urls starts with "https://music.youtube.com" then
              return "tab id " & (id of tab i of w) & " of window id " & (id of w)
            end if
          end repeat
        end repeat
      end tell
    end timeout
    return ""
    """
}
