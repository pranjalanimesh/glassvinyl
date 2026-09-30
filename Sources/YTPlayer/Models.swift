import Foundation

/// Snapshot of what YouTube Music is playing, read from the Brave tab once a second.
struct PlayerState: Decodable, Equatable {
    var videoId = ""
    var title = ""
    var artist = ""
    var album = ""
    var artworkURL: URL?
    var source: String?      // queue playlist id from the `list` URL param
    var isPlaying = false
    var isLiked = false
    var position: Double = 0
    var duration: Double = 0

    enum CodingKeys: String, CodingKey {
        case videoId, title, artist, album, source, position, duration
        case artworkURL = "artwork"
        case isPlaying = "playing"
        case isLiked = "liked"
    }
}

struct QueueItem: Decodable, Equatable, Identifiable {
    let index: Int           // position in YouTube Music's full queue, or in its autoplay list
    let videoId: String
    let title: String
    let artist: String
    let length: String
    let thumb: URL?
    let current: Bool
    let autoplay: Bool       // from the Autoplay section that follows the queue

    var id: String { "\(autoplay ? "a" : "q")\(index)-\(videoId)" }
}

/// The queue from the current song on, and the autoplay songs that follow it.
struct UpNext: Equatable {
    var queue: [QueueItem]
    var autoplay: [QueueItem]
}

struct SearchResult: Decodable, Equatable, Identifiable {
    let videoId: String
    let title: String
    let subtitle: String
    let thumb: URL?

    var id: String { videoId }
}

/// A new song suggested for the For You tab. `videoId` and `thumb` are filled in once
/// the song is found on YouTube Music.
struct Recommendation: Codable, Equatable, Identifiable {
    let title: String
    let artist: String
    let reason: String
    let source: String      // where Claude found it, or ""
    var videoId: String?
    var thumb: URL?

    var id: String { "\(title)|\(artist)" }
}

enum DrawerTab: String, CaseIterable {
    case upNext = "Up Next"
    case search = "Search"
    case forYou = "For You"
    case playlists = "Playlists"
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published var state = PlayerState()
    @Published var problem: String?
    @Published var queue: [QueueItem] = []
    @Published var autoplay: [QueueItem] = []
    @Published var results: [SearchResult] = []
    @Published var isSearching = false
    @Published var notice: String?
    @Published var isExpanded = false
    @Published var tab = DrawerTab.upNext
    @Published var recommendations: [Recommendation] = []
    @Published var recommendationsDate: Date?
    @Published var isRecommending = false
    @Published var recommendationError: String?

    /// Shows a short message under the drawer tabs for a few seconds.
    func flash(_ message: String) {
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.notice == message { self?.notice = nil }
        }
    }
}
