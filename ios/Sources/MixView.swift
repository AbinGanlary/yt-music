import SwiftUI

private let presets = ["Lo-fi", "Tamil hip-hop", "90s Bollywood", "K-pop", "Indie", "Rock", "Jazz", "EDM", "Classical", "Devotional", "Punjabi", "Telugu hits", "Workout", "Acoustic", "Focus"]

/// The songs (and, from YouTube Music, playlists) found for one genre.
struct MixGenre {
    var songs: [Track]
    var playlists: [Coll]
}

/// Mix tab: genres, moods and styles you add. Each one is searched for songs and playlists, and "Play mix" blends them.
struct MixView: View {
    @Environment(EngineHost.self) private var engine
    @Environment(PlayerModel.self) private var player
    @AppStorage("mixGenres") private var stored = ""
    @State private var loaded: [String: MixGenre] = [:]
    @AppStorage("musicSource") private var musicSource = "youtube"
    @State private var selected = "All"
    @State private var adding = false
    @State private var newName = ""

    private var genres: [String] { stored.split(separator: "|").map(String.init) }

    private func add(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !genres.contains(n) else { return }
        stored = (genres + [n]).joined(separator: "|")
    }
    private func remove(_ name: String) {
        stored = genres.filter { $0 != name }.joined(separator: "|")
        loaded[name] = nil
        if selected == name { selected = "All" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if genres.isEmpty { empty } else { filled }
                }
                .padding(.vertical, 8)
                .padding(.bottom, 140)
            }
            .background(Theme.bg)
            .navigationTitle("Mix")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                    SettingsButton()
                }
            }
            .alert("Add a genre or mood", isPresented: $adding) {
                TextField("For example Lo-fi", text: $newName)
                Button("Add") { add(newName); newName = "" }
                Button("Cancel", role: .cancel) { newName = "" }
            }
            .navigationDestination(for: Coll.self) { CollectionScreen(coll: $0) }
            .task(id: stored + "|" + musicSource + "|" + LastFM.key) { await loadMissing() }
            .onChange(of: musicSource) { _, _ in loaded = [:] }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text("Build your mixes").font(.title3.bold())
            Text("Add genres, moods or styles. Each one gets its own songs and playlists, found as soon as you add it.")
                .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            FlowChips(items: presets) { add($0) }
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
    }

    private var filled: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["All"] + genres, id: \.self) { g in
                        Button { tap(); selected = g } label: {
                            Text(g).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                                .background(selected == g ? Color.primary : Theme.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(selected == g ? 0 : 0.1)))
                                .foregroundStyle(selected == g ? Theme.bg : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }

            Button { tap(); playMix() } label: {
                Label("Play mix", systemImage: "play.fill").font(.subheadline.weight(.bold)).padding(.horizontal, 22).padding(.vertical, 11)
                    .background(Theme.accent, in: Capsule()).foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)

            ForEach(genres.filter { selected == "All" || selected == $0 }, id: \.self) { g in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(g).font(.title3.bold())
                        Spacer()
                        Button("Remove") { remove(g) }.font(.footnote).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 20)
                    if let d = loaded[g] {
                        let tracks = d.songs
                        VStack(spacing: 0) {
                            ForEach(tracks.prefix(8)) { t in
                                TrackRow(track: t, playing: player.current == t && player.isPlaying)
                                    .padding(.horizontal, 20).padding(.vertical, 6)
                                    .onTapGesture { tap(); player.play(t, in: tracks) }
                            }
                        }
                        Shelf(title: "Playlists", items: d.playlists)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                }
            }
        }
    }

    private func loadMissing() async {
        for g in genres where loaded[g] == nil {
            if LastFM.active {                                           // Last.fm as the source: the genre's top tracks
                if let list = try? await LastFM.tag(g.lowercased(), limit: 30) {
                    loaded[g] = MixGenre(songs: await SongMatcher.shared.resolveAll(list, max: 20), playlists: [])
                }
            } else if let d: GenreData = try? await engine.get("/api/genre?q=\(EngineHost.enc(g))") {
                loaded[g] = MixGenre(songs: d.songs.compactMap { Track($0) }, playlists: d.playlists)
            }
        }
    }

    /// Songs from every loaded genre, interleaved; the first few stay in order, the rest are shuffled.
    private func playMix() {
        let lists = genres.filter { selected == "All" || selected == $0 }.compactMap { loaded[$0] }.map { $0.songs }
        var seen = Set<String>()
        var out: [Track] = []
        for i in 0..<(lists.map { $0.count }.max() ?? 0) {
            for l in lists where i < l.count && !seen.contains(l[i].id) { seen.insert(l[i].id); out.append(l[i]) }
        }
        guard !out.isEmpty else { player.notify("Still finding songs…"); return }
        let mix = Array(out.prefix(6)) + out.dropFirst(6).shuffled()
        player.play(mix[0], in: mix)
    }
}

/// Tappable preset chips that wrap onto several lines.
struct FlowChips: View {
    let items: [String]
    let pick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
            ForEach(items, id: \.self) { s in
                Button { tap(); pick(s) } label: {
                    Text(s).font(.footnote.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
