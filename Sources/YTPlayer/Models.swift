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
    var position: Double = 0
    var duration: Double = 0

    enum CodingKeys: String, CodingKey {
        case videoId, title, artist, album, source, position, duration
        case artworkURL = "artwork"
        case isPlaying = "playing"
    }
}

struct QueueItem: Decodable, Equatable, Identifiable {
    let index: Int           // position in YouTube Music's full queue
    let videoId: String
    let title: String
    let artist: String
    let length: String
    let thumb: URL?
    let current: Bool

    var id: String { "\(index)-\(videoId)" }
}

struct SearchResult: Decodable, Equatable, Identifiable {
    let videoId: String
    let title: String
    let subtitle: String
    let thumb: URL?

    var id: String { videoId }
}

enum DrawerTab: String, CaseIterable {
    case upNext = "Up Next"
    case search = "Search"
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published var state = PlayerState()
    @Published var problem: String?
    @Published var queue: [QueueItem] = []
    @Published var results: [SearchResult] = []
    @Published var isSearching = false
    @Published var notice: String?
    @Published var isExpanded = false
    @Published var tab = DrawerTab.upNext
}
