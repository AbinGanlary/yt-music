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
    @Environment(PlayerModel.self) private var player
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
    @Environment(PlayerModel.self) private var player
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
            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 0))
        }
    }
}

struct HomeView: View {
    @Environment(EngineHost.self) private var engine
    @Environment(PlayerModel.self) private var player
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
    @State private var quick: [Track] = []
    @State private var noResults = false
    @State private var trending: [Track] = []
    @AppStorage("musicSource") private var musicSource = "youtube"        // "youtube" or "lastfm" (Settings)
    @AppStorage("lastfmKey") private var lastfmKey = ""
    @State private var lfmTags: [String] = []
    @State private var because: [Track] = []
    @State private var becauseTitle = ""
    @State private var results: [Track] = []
    @State private var heading = "Quick picks"
    @State private var query = ""
    @State private var suggestions: [String] = []
    @State private var busy = false
    @State private var error: String?
    private let moods = ["All", "Relax", "Sleep", "Energize", "Sad", "Romance", "Focus", "Party"]

    private var lfm: Bool { musicSource == "lastfm" && !lastfmKey.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The chips under the search box: moods, or Last.fm's most used tags when Last.fm is the source.
    private var moodNames: [String] { lfm ? ["All"] + lfmTags.prefix(7).map { $0.prefix(1).uppercased() + $0.dropFirst() } : moods }

    private func on(_ id: String) -> Bool { !hidden.split(separator: ",").contains(Substring(id)) }
    private var recent: [String] { recentStore.split(separator: "|").map(String.init) }

    var body: some View {
        NavigationStack {
            List {
                if on("moods") && mood != -1 {                  // not while looking at search results
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(moodNames.indices, id: \.self) { i in
                                Button {
                                    tap()
                                    withAnimation(.easeOut(duration: 0.2)) { mood = i }
                                    if i == 0 { results = []; noResults = false; heading = "Quick picks" }
                                    else if lfm { runTag(lfmTags[i - 1]) }
                                    else { run("\(moods[i]) songs", heading: moods[i]) }
                                } label: {
                                    Text(moodNames[i]).font(.subheadline.weight(.semibold))
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
                if noResults {
                    Text("No results for “\(query)”. Try another spelling or fewer words.").font(.subheadline).foregroundStyle(Theme.muted)
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
                    VStack(alignment: .leading, spacing: 0) {
                        if results.isEmpty { Text("Start radio from a song").font(.footnote).foregroundStyle(Theme.muted) }
                        Text(results.isEmpty ? heading : (mood == -1 ? "Results for \(heading)" : heading))
                            .font(results.isEmpty ? .title.bold() : .title2.bold())
                            .foregroundStyle(Color.primary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))

                    if busy || (results.isEmpty && quick.isEmpty && error == nil) {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    SongList(tracks: results.isEmpty ? quick : results)
                }

                if results.isEmpty && on("trend") && !lfm { TrackShelf(title: "Trending", tracks: trending) }
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
            .sheet(isPresented: $showTaste) { TasteSheet().environment(engine) }
            .sheet(isPresented: $showList) { SearchListView().environment(engine).environment(player) }
            .navigationDestination(for: Coll.self) { CollectionScreen(coll: $0) }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search songs")
            .searchSuggestions {
                ForEach(query.isEmpty ? recent : suggestions, id: \.self) { s in
                    Button {                                            // tapping a suggestion searches straight away
                        query = s
                        mood = -1
                        remember(s)
                        run(s, heading: "“\(s)”")
                    } label: { Label(s, systemImage: query.isEmpty ? "clock" : "magnifyingglass") }
                }
            }
            .onSubmit(of: .search) { mood = -1; remember(query); run(query, heading: "“\(query)”") }
            .task(id: query) { await loadSuggestions() }
            .task(id: musicSource + "|" + lastfmKey) {                  // choosing a different music source in Settings reloads Home
                results = []
                noResults = false
                mood = 0
                heading = "Quick picks"
                quick = []
                await loadAll()
            }
            .refreshable { await loadAll() }
            .onChange(of: query) { _, q in                                 // clearing the search box (or cancelling it) goes back to Home
                if q.trimmingCharacters(in: .whitespaces).isEmpty && mood == -1 {
                    results = []
                    noResults = false
                    heading = "Quick picks"
                    mood = 0
                }
            }
            .miniPlayerClearance()
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

    /// Home with Last.fm as the source: the chart as Quick picks, similar songs, and your picks from Last.fm's artist and tag lists.
    private func loadLastFM() async {
        error = nil
        ytShelves = []
        trending = []
        do {
            let loc = EngineHost.loc()
            let list = try await (loc.isEmpty ? LastFM.chart(limit: 40) : LastFM.country(loc, limit: 40))
            quick = await SongMatcher.shared.resolveAll(list, max: 20)
        } catch { self.error = error.localizedDescription }
        if lfmTags.isEmpty { lfmTags = (try? await LastFM.topTags(limit: 8)) ?? [] }

        if on("because"), let last = player.lib.history.first, last.id.count >= 11 {
            becauseTitle = last.title
            let artist = last.artist.components(separatedBy: ", ").first ?? last.artist
            if let list = try? await LastFM.similar(artist: artist, track: last.title) {
                because = Array((await SongMatcher.shared.resolveAll(list, max: 14)).filter { $0.id != last.id })
            }
        }
        let artists = Taste.artists(tasteArtists), langs = Taste.langs(tasteLangs)
        if on("mix"), !artists.isEmpty || !langs.isEmpty {
            pickedLabel = (artists.prefix(2).map { $0.name } + langs.prefix(1)).joined(separator: ", ")
            var out: [Track] = []
            for a in artists.prefix(3) {
                if let list = try? await LastFM.artistTopTracks(a.name, limit: 6) { out += await SongMatcher.shared.resolveAll(list, max: 5) }
            }
            for l in langs.prefix(2) {
                if let list = try? await LastFM.tag(l.lowercased(), limit: 8) { out += await SongMatcher.shared.resolveAll(list, max: 6) }
            }
            var seen = Set<String>()
            picked = Array(out.filter { seen.insert($0.id).inserted }.shuffled().prefix(16))
        } else { picked = [] }
    }

    private func runTag(_ t: String) {
        busy = true
        error = nil
        noResults = false
        Task {
            do {
                let list = try await LastFM.tag(t, limit: 40)
                results = await SongMatcher.shared.resolveAll(list, max: 30)
                heading = t.prefix(1).uppercased() + t.dropFirst()
                noResults = results.isEmpty
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func loadAll() async {
        if lfm { await loadLastFM(); return }
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
        noResults = false
        Task {
            do {
                let r = try await engine.search(text)
                results = r
                heading = h
                noResults = r.isEmpty
            } catch { self.error = "Search failed: " + String(error.localizedDescription.prefix(160)) }
            busy = false
        }
    }
}
