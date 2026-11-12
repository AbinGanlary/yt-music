import SwiftUI

struct TrackRow: View {
    let track: Track
    let playing: Bool
    var body: some View {
        HStack(spacing: 12) {
            Cover(track: track, radius: 8).frame(width: 52, height: 52)
                .overlay {
                    if playing { Image(systemName: "waveform").foregroundStyle(.white) }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if playing { Image(systemName: "waveform").font(.caption.weight(.bold)).foregroundStyle(Theme.accent) }
                    Text(track.title).font(.body.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(1)
                }
                Text(track.artist).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Text(clock(Double(track.seconds))).font(.footnote.monospacedDigit()).foregroundStyle(Theme.muted)
        }
        .contentShape(Rectangle())
    }
}

/// Song list with the same swipes as the web app: right = like, left = play next.
struct SongList: View {
    @EnvironmentObject var player: PlayerModel
    let tracks: [Track]
    var onRemove: ((Track) -> Void)? = nil

    var body: some View {
        ForEach(tracks) { t in
            TrackRow(track: t, playing: player.current == t && player.isPlaying)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .onTapGesture { tap(); player.play(t, in: tracks) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { tap(.medium); player.toggleLike(t) } label: {
                        Label("Like", systemImage: player.liked.contains(t.id) ? "heart.slash" : "heart.fill")
                    }
                    .tint(Theme.accent)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if let remove = onRemove {
                        Button(role: .destructive) { tap(.medium); remove(t) } label: { Label("Remove", systemImage: "trash") }
                    } else {
                        Button { tap(.medium); player.playNext(t) } label: {
                            Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        .tint(.indigo)
                    }
                }
                .contextMenu {
                    Button { player.startRadio(t) } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
                    Button { player.playNext(t) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button { player.addToQueue(t) } label: { Label("Add to queue", systemImage: "text.append") }
                    Menu {
                        ForEach(player.lib.playlists) { p in
                            Button(p.name) { player.add(t, to: p) }
                        }
                        Button { player.requestPlaylist(for: t) } label: { Label("New playlist…", systemImage: "plus") }
                    } label: { Label("Add to playlist", systemImage: "music.note.list") }
                    Button { player.toggleLike(t) } label: {
                        Label(player.liked.contains(t.id) ? "Remove from liked" : "Like", systemImage: player.liked.contains(t.id) ? "heart.slash" : "heart")
                    }
                    if player.downloads.has(t.id) {
                        Button(role: .destructive) { player.removeDownload(t) } label: { Label("Remove download", systemImage: "trash") }
                    } else {
                        Button { player.saveOffline(t) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    }
                    Button { player.saveToFiles(t) } label: { Label("Save to Files…", systemImage: "square.and.arrow.up") }
                }
        }
    }
}

/// A horizontal row of song cards.
struct TrackShelf: View {
    @EnvironmentObject var player: PlayerModel
    let title: String
    var subtitle: String? = nil
    let tracks: [Track]

    var body: some View {
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    if let s = subtitle { Text(s).font(.footnote).foregroundStyle(Theme.muted) }
                    Text(title).font(.title2.bold())
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(tracks) { t in
                            VStack(alignment: .leading, spacing: 5) {
                                Cover(track: t, radius: 12).frame(width: 130, height: 130)
                                Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1).frame(width: 130, alignment: .leading)
                                Text(t.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 130, alignment: .leading)
                            }
                            .onTapGesture { tap(); player.play(t, in: tracks) }
                            .contextMenu {
                                Button { player.startRadio(t) } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
                                Button { player.playNext(t) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                                Button { player.toggleLike(t) } label: { Label("Like", systemImage: "heart") }
                            }
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 0))
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var engine: EngineHost
    @EnvironmentObject var player: PlayerModel
    @AppStorage("homeHide") private var hidden = ""             // comma-separated section ids switched off in Settings
    @AppStorage("recentSearches") private var recentStore = ""
    @AppStorage("ytSignedIn") private var signedIn = false
    @State private var ytShelves: [YTShelf] = []
    @State private var showList = false
    @AppStorage("tasteLangs") private var tasteLangs = ""
    @AppStorage("tasteArtists") private var tasteArtists = ""
    @AppStorage("hideTaste") private var hideTaste = false
    @State private var showTaste = false
    @State private var picked: [Track] = []
    @State private var pickedLabel = ""
    @State private var mood = 0
    @State private var quick: [Track] = sampleTracks
    @State private var trending: [Track] = []
    @State private var because: [Track] = []
    @State private var becauseTitle = ""
    @State private var results: [Track] = []
    @State private var heading = "Quick picks"
    @State private var query = ""
    @State private var suggestions: [String] = []
    @State private var busy = false
    @State private var error: String?
    private let moods = ["All", "Relax", "Sleep", "Energize", "Sad", "Romance", "Focus", "Party"]

    private func on(_ id: String) -> Bool { !hidden.split(separator: ",").contains(Substring(id)) }
    private var recent: [String] { recentStore.split(separator: "|").map(String.init) }

    var body: some View {
        NavigationStack {
            List {
                if on("moods") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(moods.indices, id: \.self) { i in
                                Button {
                                    tap()
                                    withAnimation(.easeOut(duration: 0.2)) { mood = i }
                                    if i == 0 { results = []; heading = "Quick picks" } else { run("\(moods[i]) songs", heading: moods[i]) }
                                } label: {
                                    Text(moods[i]).font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(mood == i ? Color.primary : Theme.surface, in: Capsule())
                                        .overlay(Capsule().strokeBorder(Color.primary.opacity(mood == i ? 0 : 0.1)))
                                        .foregroundStyle(mood == i ? Theme.bg : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if let e = error {
                    Text(e).font(.caption2).foregroundStyle(Color.red)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }

                if results.isEmpty && tasteLangs.isEmpty && tasteArtists.isEmpty && !hideTaste {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text("**Make it yours.** Pick your music languages and a few artists you like, and Home gets a “Picked for you” shelf.")
                                .font(.subheadline)
                            Spacer()
                            Button { hideTaste = true } label: { Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(Theme.muted) }
                                .buttonStyle(.plain)
                        }
                        Button("Pick now") { showTaste = true }
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(Color.black)
                            .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if results.isEmpty {
                    if on("mix") { TrackShelf(title: "Picked for you", subtitle: pickedLabel, tracks: picked) }
                    ForEach(Array(ytShelves.enumerated()), id: \.offset) { _, shelf in
                        if !shelf.tracks.isEmpty {
                            TrackShelf(title: shelf.title, subtitle: "From your YouTube Music", tracks: shelf.tracks.compactMap { Track($0) })
                        } else {
                            Shelf(title: shelf.title, items: shelf.colls)
                                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                        }
                    }
                    if on("listen") { TrackShelf(title: "Listen again", tracks: Array(player.lib.history.prefix(12))) }
                    if on("because") { TrackShelf(title: becauseTitle, subtitle: "Because you played", tracks: because) }
                }

                if on("quick") || !results.isEmpty {
                    Section {
                        if busy { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden) }
                        SongList(tracks: results.isEmpty ? quick : results)
                    } header: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(results.isEmpty ? "Start radio from a song" : "Results").font(.footnote).foregroundStyle(Theme.muted)
                            Text(heading).font(.title.bold()).foregroundStyle(Color.primary)
                        }
                        .textCase(nil)
                        .padding(.top, 8)
                    }
                }

                if results.isEmpty && on("trend") { TrackShelf(title: "Trending", tracks: trending) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("YT Music")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showList = true } label: { Image(systemName: "list.bullet.rectangle") }
                        .accessibilityLabel("Search a list")
                    SettingsButton()
                }
            }
            .sheet(isPresented: $showTaste) { TasteSheet().environmentObject(engine) }
            .sheet(isPresented: $showList) { SearchListView().environmentObject(engine).environmentObject(player) }
            .navigationDestination(for: Coll.self) { CollectionScreen(coll: $0) }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search songs")
            .searchSuggestions {
                ForEach(query.isEmpty ? recent : suggestions, id: \.self) { s in
                    Label(s, systemImage: query.isEmpty ? "clock" : "magnifyingglass").searchCompletion(s)
                }
            }
            .onSubmit(of: .search) { mood = -1; remember(query); run(query, heading: "“\(query)”") }
            .task(id: query) { await loadSuggestions() }
            .task { await loadAll() }
            .refreshable { await loadAll() }
        }
    }

    private func remember(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        recentStore = ([t] + recent.filter { $0 != t }).prefix(8).joined(separator: "|")
    }

    private func loadSuggestions() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { suggestions = []; return }
        try? await Task.sleep(nanoseconds: 250_000_000)             // wait for a pause in typing
        if Task.isCancelled { return }
        if let s: [String] = try? await engine.get("/api/suggest?q=\(EngineHost.enc(q))") { suggestions = Array(s.prefix(8)) }
    }

    private func loadAll() async {
        do {
            let t = try await engine.quickPicks()
            if !t.isEmpty { quick = t }
            error = nil
        } catch { self.error = "Home failed: " + String(error.localizedDescription.prefix(160)) }
        if signedIn, let shelves: [YTShelf] = try? await engine.get("/api/ythome") { ytShelves = shelves } else if !signedIn { ytShelves = [] }
        let loc = EngineHost.loc()
        if on("trend"), let raw: [RawTrack] = try? await engine.get("/api/trending?country=\(loc.isEmpty ? "ZZ" : loc)") { trending = raw.compactMap { Track($0) } }
        let artists = Taste.artists(tasteArtists), langs = Taste.langs(tasteLangs)
        if on("mix"), !artists.isEmpty || !langs.isEmpty {
            let ids = artists.prefix(6).map { $0.id }.joined(separator: ",")
            let l = EngineHost.enc(langs.prefix(3).joined(separator: ","))
            pickedLabel = (artists.prefix(2).map { $0.name } + langs.prefix(1)).joined(separator: ", ")
            if let raw: [RawTrack] = try? await engine.get("/api/mix?artists=\(EngineHost.enc(ids))&langs=\(l)") { picked = raw.compactMap { Track($0) }.prefix(16).map { $0 } }
        } else { picked = [] }
        if on("because"), let last = player.lib.history.first, last.id.count >= 11 {
            becauseTitle = last.title
            if let r = try? await engine.radio(last.id) { because = Array(r.filter { $0.id != last.id }.prefix(14)) }
        }
    }

    private func run(_ q: String, heading h: String) {
        let text = q.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        busy = true
        error = nil
        Task {
            do {
                let r = try await engine.search(text)
                results = r
                heading = h
                if r.isEmpty { error = "No results" }
            } catch { self.error = "Search failed: " + String(error.localizedDescription.prefix(160)) }
            busy = false
        }
    }
}
