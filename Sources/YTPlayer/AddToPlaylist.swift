import SwiftUI

/// "Add to Playlist" for any song, in two forms: a SwiftUI menu for context menus and ⊕
/// menus, and an AppKit submenu for rows whose right-click RowDragArea handles.
/// Playlists that already contain the song are shown ticked and disabled.
@MainActor
enum AddToPlaylist {
    /// Playlists a song can be added to. Liked Music is left out; the heart handles likes.
    static func targets(_ library: LibraryStore) -> [LibraryPlaylist] {
        library.musicPlaylists.filter { !$0.isLiked }
    }

    static func add(_ track: PlaylistTrack, to list: LibraryPlaylist, library: LibraryStore, model: PlayerModel) {
        Task {
            do {
                try await library.add(track, to: list.id)
                model.flash("Added \(track.title) to \(list.title)")
            } catch {
                model.flash("Couldn't add: \(error.localizedDescription)")
            }
        }
    }

    static func menuItem(for track: PlaylistTrack, library: LibraryStore, model: PlayerModel) -> NSMenuItem {
        let item = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let lists = targets(library)
        if lists.isEmpty {
            let empty = NSMenuItem(title: "No playlists synced yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for list in lists {
            let added = library.contains(track.videoId, in: list.id)
            let entry = ClosureMenuItem(title: list.title) { add(track, to: list, library: library, model: model) }
            entry.state = added ? .on : .off
            entry.isEnabled = !added
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }
}

/// SwiftUI "Add to Playlist" submenu.
struct AddToPlaylistMenu: View {
    let track: PlaylistTrack
    @ObservedObject var library: LibraryStore
    let model: PlayerModel

    var body: some View {
        Menu("Add to Playlist") {
            let lists = AddToPlaylist.targets(library)
            if lists.isEmpty {
                Text("No playlists synced yet")
            }
            ForEach(lists) { list in
                let added = library.contains(track.videoId, in: list.id)
                Button {
                    AddToPlaylist.add(track, to: list, library: library, model: model)
                } label: {
                    if added { Label(list.title, systemImage: "checkmark") } else { Text(list.title) }
                }
                .disabled(added)
            }
        }
    }
}

extension PlaylistTrack {
    init(_ item: QueueItem) {
        self.init(videoId: item.videoId, setVideoId: nil, title: item.title, artist: item.artist,
                  length: item.length, thumb: item.thumb, type: "MUSIC_VIDEO_TYPE_ATV")
    }

    /// Search subtitles read like "Song • Artist • Album"; the artist is the part after the kind.
    init(_ result: SearchResult) {
        var parts = result.subtitle.components(separatedBy: " • ")
        if let kind = parts.first, ["Song", "Video", "Episode", "Podcast"].contains(kind) { parts.removeFirst() }
        self.init(videoId: result.videoId, setVideoId: nil, title: result.title, artist: parts.first ?? "",
                  length: "", thumb: result.thumb, type: "MUSIC_VIDEO_TYPE_ATV")
    }
}
