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

    var onPoll: ((PlayerState, [QueueItem]?) -> Void)?
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
    func next() { fire("__ytp.next()") }
    func previous() { fire("__ytp.previous()") }
    func seek(to seconds: Double) { fire("__ytp.seek(\(seconds))") }

    // MARK: - Queue

    enum InsertPosition: String {
        case next = "INSERT_AFTER_CURRENT_VIDEO"
        case end = "INSERT_AT_END"
    }

    func add(_ videoId: String, at position: InsertPosition) {
        fire("__ytp.add(\(literal(videoId)), \(literal(position.rawValue)))")
    }
    func playNow(_ videoId: String) { fire("__ytp.playNow(\(literal(videoId)))") }
    func jump(to index: Int) { fire("__ytp.jump(\(index))") }
    func remove(at index: Int) { fire("__ytp.remove(\(index))") }

    // MARK: - Search

    func search(_ query: String, completion: @escaping (Result<[SearchResult], Error>) -> Void) {
        let id = UUID().uuidString
        call("__ytp.search(\(literal(id)), \(literal(query)))") { [weak self] result in
            if case .failure(let error) = result { return completion(.failure(error)) }
            self?.awaitSearch(id, attemptsLeft: 40, completion: completion)
        }
    }

    private struct SearchResponse: Decodable {
        let results: [SearchResult]?
        let error: String?
    }

    private func awaitSearch(_ id: String, attemptsLeft: Int,
                             completion: @escaping (Result<[SearchResult], Error>) -> Void) {
        guard attemptsLeft > 0 else { return completion(.failure(BridgeError("Search timed out"))) }
        call("__ytp.result(\(literal(id)))") { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                guard let response = try? JSONDecoder().decode(SearchResponse.self, from: Data(json.utf8)) else {
                    // Still running.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self?.awaitSearch(id, attemptsLeft: attemptsLeft - 1, completion: completion)
                    }
                    return
                }
                if let error = response.error { return completion(.failure(BridgeError(error))) }
                completion(.success(response.results ?? []))
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
    }

    func poll() {
        guard !isPolling else { return }
        isPolling = true
        call("__ytp.poll(\(wantsQueue))") { [weak self] result in
            guard let self else { return }
            self.isPolling = false
            switch result {
            case .success(let json):
                guard let response = try? JSONDecoder().decode(PollResponse.self, from: Data(json.utf8)) else { return }
                self.onProblem?(nil)
                self.onPoll?(response.state, response.queue)
            case .failure(let error):
                self.onProblem?(error.localizedDescription)
                self.onPoll?(PlayerState(), nil)
            }
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
        BraveScript.jsLiteral(string)
    }
}

/// AppleScript plumbing. Everything here runs on `queue`, one script at a time.
private enum BraveScript {
    static let queue = DispatchQueue(label: "ytplayer.applescript")

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
            case -1743: message = "Allow YTPlayer to control Brave in System Settings > Privacy > Automation"
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
