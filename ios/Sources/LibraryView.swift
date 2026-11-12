import SwiftUI
import UniformTypeIdentifiers

enum LibSource: Hashable {
    case likes
    case history
    case downloads
    case playlist(UUID)
}

struct LibraryView: View {
    @EnvironmentObject var player: PlayerModel
    @State private var picking = false
    @State private var showSettings = false
    @State private var showList = false
    @AppStorage("ytSignedIn") private var signedIn = false
    @EnvironmentObject var engine: EngineHost

    var body: some View {
        let lib = player.lib
        NavigationStack {
            List {
                NavigationLink(value: LibSource.likes) {
                    entry("heart.fill", "Liked songs", "\(lib.likes.count) songs")
                }
                .listRowBackground(Color.clear)
                if signedIn {
                    NavigationLink(value: Coll(kind: "liked", id: "LM", title: "YouTube liked music", subtitle: "YouTube Music", thumbnail: nil)) {
                        entry("play.rectangle.fill", "YouTube liked music", "From your account")
                    }
                    .listRowBackground(Color.clear)
                }
                NavigationLink(value: LibSource.downloads) {
                    entry("arrow.down.circle.fill", "Downloads", "\(player.downloads.tracks.count) songs")
                }
                .listRowBackground(Color.clear)
                NavigationLink(value: LibSource.history) {
                    entry("clock.fill", "History", "\(lib.history.count) songs")
                }
                .listRowBackground(Color.clear)

                Section {
                    ForEach(lib.playlists) { p in
                        NavigationLink(value: LibSource.playlist(p.id)) {
                            entry("music.note.list", p.name, "\(p.tracks.count) songs")
                        }
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button { player.renaming = p.id } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { lib.deletePlaylist(p.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { lib.deletePlaylist(lib.playlists[i].id) }
                    }
                } header: {
                    HStack {
                        Text("Playlists").font(.title3.bold()).foregroundStyle(Color.primary).textCase(nil)
                        Spacer()
                        Button { player.requestPlaylist(for: nil) } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                    }
                }

                if !lib.saved.isEmpty {
                    Section {
                        ForEach(lib.saved) { c in
                            NavigationLink(value: c) {
                                entry(c.kind == "artist" ? "person.fill" : c.kind == "album" ? "square.stack.fill" : "music.note.list", c.title, c.subtitle ?? "")
                            }
                            .listRowBackground(Color.clear)
                        }
                        .onDelete { offsets in
                            for i in offsets { lib.toggleSaved(lib.saved[i]) }
                        }
                    } header: {
                        Text("Saved").font(.title3.bold()).foregroundStyle(Color.primary).textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    SettingsButton()
                    Menu {
                        Button { picking = true } label: { Label("Import web app backup", systemImage: "square.and.arrow.down") }
                        Button { exportBackup() } label: { Label("Back up to a file", systemImage: "square.and.arrow.up") }
                        Button { showList = true } label: { Label("Search a list", systemImage: "list.bullet.rectangle") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let r = try player.lib.importWebBackup(try Data(contentsOf: url))
                        player.notify("Imported \(r.likes) likes, \(r.playlists) playlists, \(r.history) history, \(r.plays) plays")
                    } catch { player.notify("Import failed: " + error.localizedDescription) }
                case .failure(let e):
                    player.notify("Couldn't open the file: " + e.localizedDescription)
                }
            }
            .navigationDestination(for: LibSource.self) { TrackListScreen(source: $0) }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(player).environmentObject(engine) }
            .sheet(isPresented: $showList) { SearchListView().environmentObject(engine).environmentObject(player) }
            .navigationDestination(for: Coll.self) { CollectionScreen(coll: $0) }
        }
    }

    /// A backup file in the web app's format (the web app can restore it too), handed to the share sheet.
    private func exportBackup() {
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("YT-Music-backup-\(day).json")
        do {
            try player.lib.exportWebBackup().write(to: file, options: .atomic)
            player.shareItem = ShareItem(url: file)
        } catch { player.notify("Couldn't make the backup: " + error.localizedDescription) }
    }

    private func entry(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One list of songs: liked, history, or a playlist. It reads from the library each time, so it stays current.
struct TrackListScreen: View {
    @EnvironmentObject var player: PlayerModel
    let source: LibSource

    private var title: String {
        switch source {
        case .likes: return "Liked songs"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .playlist(let id): return player.lib.playlist(id)?.name ?? "Playlist"
        }
    }
    private var tracks: [Track] {
        switch source {
        case .likes: return player.lib.likes
        case .history: return player.lib.history
        case .downloads: return player.downloads.tracks
        case .playlist(let id): return player.lib.playlist(id)?.tracks ?? []
        }
    }

    var body: some View {
        let list = tracks
        List {
            if list.isEmpty {
                Text(source == .likes ? "Swipe a song right to like it." : source == .history ? "Songs you play show up here." : source == .downloads ? "Long-press a song and choose Download." : "Long-press a song and choose Add to playlist.")
                    .foregroundStyle(Theme.muted)
                    .listRowBackground(Color.clear)
            } else {
                SongList(tracks: list, onRemove: removeAction)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !list.isEmpty {
                    Button { tap(); player.play(list[0], in: list) } label: { Label("Play all", systemImage: "play.fill") }
                }
            }
            if case .playlist(let pid) = source {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { player.renaming = pid } label: { Image(systemName: "pencil") }
                        .accessibilityLabel("Rename playlist")
                }
            }
            if source == .history && !list.isEmpty {
                ToolbarItem(placement: .navigationBarLeading) { Button("Clear") { player.lib.clearHistory() } }
            }
        }
    }

    private var removeAction: ((Track) -> Void)? {
        switch source {
        case .playlist(let id): return { t in player.lib.remove(t, from: id) }
        case .likes: return { t in player.lib.toggleLike(t) }
        case .downloads: return { t in player.removeDownload(t) }
        case .history: return nil
        }
    }
}
