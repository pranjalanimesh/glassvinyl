import SwiftUI

/// Expandable panel under the player: the Up Next queue and search.
struct DrawerView: View {
    @ObservedObject var model: PlayerModel
    let bridge: PlayerBridge

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $model.tab) {
                ForEach(DrawerTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.tab {
            case .upNext: QueueList(model: model, bridge: bridge)
            case .search: SearchPane(model: model, bridge: bridge)
            }

            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct QueueList: View {
    @ObservedObject var model: PlayerModel
    let bridge: PlayerBridge

    var body: some View {
        if model.queue.isEmpty {
            Text("Queue is empty").foregroundStyle(.secondary).frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.queue) { item in
                        SongRow(title: item.title, subtitle: item.artist, thumb: item.thumb, highlighted: item.current) {
                            if item.current {
                                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11))
                            } else {
                                Text(item.length).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                                Button {
                                    bridge.remove(at: item.index)
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Remove from queue")
                            }
                        }
                        .onTapGesture { if !item.current { bridge.jump(to: item.index) } }
                        .contextMenu {
                            Button("Play") { bridge.jump(to: item.index) }
                            Button("Remove from Queue") { bridge.remove(at: item.index) }
                        }
                    }
                }
            }
        }
    }
}

private struct SearchPane: View {
    @ObservedObject var model: PlayerModel
    let bridge: PlayerBridge
    @State private var query = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search songs, artists…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(runSearch)
                if model.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(7)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.results) { result in
                        SongRow(title: result.title, subtitle: result.subtitle, thumb: result.thumb, highlighted: false) {
                            Menu {
                                Button("Play Now") { act("Playing \(result.title)") { bridge.playNow(result.videoId) } }
                                Button("Play Next") { act("\(result.title) plays next") { bridge.add(result.videoId, at: .next) } }
                                Button("Add to Queue") { act("Added \(result.title)") { bridge.add(result.videoId, at: .end) } }
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.visible)
                            .fixedSize()
                        }
                    }
                }
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        model.isSearching = true
        bridge.search(q) { result in
            model.isSearching = false
            switch result {
            case .success(let results): model.results = results
            case .failure(let error): show(error.localizedDescription)
            }
        }
    }

    private func act(_ message: String, _ action: () -> Void) {
        action()
        show(message)
    }

    private func show(_ message: String) {
        model.notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if model.notice == message { model.notice = nil }
        }
    }
}

/// Thumbnail, two lines of text, and trailing accessories.
private struct SongRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    let thumb: URL?
    let highlighted: Bool
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: thumb) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                Color.white.opacity(0.1)
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            accessory
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(highlighted ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}
