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


extension View {
    /// A full-width row in Home's list: no background, no separator, edge to edge.
    func homeRow(top: CGFloat = 8, bottom: CGFloat = 8) -> some View {
        self.listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0))
    }
}

struct HomeView: View {
    @Environment(EngineHost.self) private var engine
    @Environment(PlayerModel.self) private var player
    @Environment(TabRouter.self) private var router
    @AppStorage("homeHide") private var hidden = ""             // comma-separated section ids switched off in Settings
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
    @State private var trending: [Track] = []
    @AppStorage("musicSource") private var musicSource = "youtube"        // "youtube" or "lastfm" (Settings)
    @AppStorage("lastfmKey") private var lastfmKey = ""
    @State private var lfmTags: [String] = []
    @State private var because: [Track] = []
    @State private var becauseTitle = ""
    @State private var results: [Track] = []
    @State private var heading = ""
    @State private var busy = false
    @State private var error: String?
    @State private var mixes: [HomeMix] = []
    @State private var mixesLoaded = false
    @State private var recents: [Coll] = []
    private let moods = ["All", "Relax", "Sleep", "Energize", "Sad", "Romance", "Focus", "Party"]

    private var lfm: Bool { musicSource == "lastfm" && !lastfmKey.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The chips at the top: moods, or Last.fm's most used tags when Last.fm is the source.
    private var moodNames: [String] { lfm ? ["All"] + lfmTags.prefix(7).map { $0.prefix(1).uppercased() + $0.dropFirst() } : moods }
    private var showingMood: Bool { mood > 0 }

    private func on(_ id: String) -> Bool { !hidden.split(separator: ",").contains(Substring(id)) }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }

    var body: some View {
        NavigationStack {
            List {
                if on("moods") { moodChips.homeRow(top: 4, bottom: 6) }

                if let e = error {
                    Text(e).font(.caption2).foregroundStyle(Color.red).padding(.horizontal, 20).homeRow()
                }

                if showingMood {
                    SectionHeader(title: heading) {
                        if !results.isEmpty { PillButton(title: "Play all", icon: "play.fill") { player.play(results[0], in: results) } }
                    }
                    .homeRow(top: 10, bottom: 4)
                    if busy { RowsPlaceholder(count: 6).homeRow() }
                    SongList(tracks: results)
                } else {
                    homeSections
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(greeting)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { tap(); router.focusSearch = true; router.tab = 2 } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search")
                    Button { showList = true } label: { Image(systemName: "list.bullet.rectangle") }
                        .accessibilityLabel("Search a list")
                    SettingsButton()
                }
            }
            .sheet(isPresented: $showTaste) { TasteSheet().environment(engine) }
            .sheet(isPresented: $showList) { SearchListView().environment(engine).environment(player) }
            .navigationDestination(for: Coll.self) { CollectionScreen(coll: $0) }
            .navigationDestination(for: LibSource.self) { TrackListScreen(source: $0) }
            .navigationDestination(for: SongsPage.self) { SongsScreen(page: $0) }
            .task(id: musicSource + "|" + lastfmKey) {                  // choosing a different music source in Settings reloads Home
                results = []
                mood = 0
                quick = []
                await loadAll()
            }
            .refreshable { mixesLoaded = false; await loadAll() }
            .onAppear { recents = RecentPages.all() }
            .miniPlayerClearance()
        }
    }

    // MARK: - sections

    @ViewBuilder private var homeSections: some View {
        if tasteLangs.isEmpty && tasteArtists.isEmpty && !hideTaste { tasteCard.homeRow() }

        if on("jump") { jumpGrid.homeRow(top: 4, bottom: 10) }

        if on("made") && !mixes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Made for you")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(mixes) { MixCard(mix: $0) }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .homeRow()
        } else if on("made") && !mixesLoaded && !player.lib.plays.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Made for you")
                ShelfPlaceholder(size: 150)
            }
            .homeRow()
        }

        if on("quick") {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Quick picks", subtitle: "Start radio from a song") {
                    if !quick.isEmpty { PillButton(title: "Play all", icon: "play.fill") { player.play(quick[0], in: quick) } }
                }
                if quick.isEmpty && error == nil { RowsPlaceholder(count: 4) } else { QuickPicksGrid(tracks: quick) }
            }
            .homeRow()
        }

        if on("mix") { TrackShelf(title: "Picked for you", subtitle: pickedLabel, tracks: picked) }
        ForEach(Array(ytShelves.enumerated()), id: \.offset) { _, shelf in
            if !shelf.tracks.isEmpty {
                TrackShelf(title: shelf.title, subtitle: "From your YouTube Music", tracks: shelf.tracks.compactMap { Track($0) })
            } else {
                Shelf(title: shelf.title, items: shelf.colls).homeRow(top: 10, bottom: 10)
            }
        }
        if on("listen") { TrackShelf(title: "Listen again", tracks: Array(player.lib.history.prefix(12))) }
        if on("because") { TrackShelf(title: becauseTitle, subtitle: "Because you played", tracks: because) }
        if on("trend") && !lfm { TrackShelf(title: "Trending", tracks: trending) }
    }

    private var moodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(moodNames.indices, id: \.self) { i in
                    Button {
                        tap()
                        withAnimation(.easeOut(duration: 0.2)) { mood = i }
                        if i == 0 { results = [] }
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
            .padding(.horizontal, 20)
        }
    }

    private var tasteCard: some View {
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
        .padding(.horizontal, 20)
    }

    /// Six tiles: Liked songs, Downloads, then the albums and playlists you opened lately (or History).
    private var jumpGrid: some View {
        let pages = Array(recents.prefix(4))
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            NavigationLink(value: LibSource.likes) {
                JumpTile(title: "Liked songs") { SymbolArt(symbol: "heart.fill", colors: [Theme.accent, .purple]) }
            }
            NavigationLink(value: LibSource.downloads) {
                JumpTile(title: "Downloads") { SymbolArt(symbol: "arrow.down.circle.fill", colors: [.teal, .blue]) }
            }
            ForEach(pages) { c in
                NavigationLink(value: c) {
                    JumpTile(title: c.title) { RemoteSquare(url: c.url) }
                }
                .contextMenu {
                    Button { Task { await playCollection(c, engine: engine, player: player) } } label: { Label("Play", systemImage: "play.fill") }
                    Button { Task { await playCollection(c, engine: engine, player: player, shuffle: true) } } label: { Label("Shuffle", systemImage: "shuffle") }
                }
            }
            if pages.count < 4 {
                NavigationLink(value: LibSource.history) {
                    JumpTile(title: "History") { SymbolArt(symbol: "clock.fill", colors: [.indigo, .black]) }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }

    // MARK: - loading

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
        results = []
        heading = t.prefix(1).uppercased() + t.dropFirst()
        Task {
            do {
                let list = try await LastFM.tag(t, limit: 40)
                results = await SongMatcher.shared.resolveAll(list, max: 30)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func loadAll() async {
        recents = RecentPages.all()
        if lfm { await loadLastFM() } else {
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
        if on("made") && !mixesLoaded { await buildMixes() }
    }

    /// "Made for you": two mixes from the artists you play most (your own songs by them, plus their radios),
    /// and "Discover": songs like the ones you like that you have not played yet.
    private func buildMixes() async {
        let history = player.lib.history
        var count: [String: Int] = [:]
        for p in player.lib.plays.suffix(3000) where p.secs >= 30 {
            let a = p.artist.components(separatedBy: ", ").first ?? p.artist
            if !a.isEmpty { count[a, default: 0] += 1 }
        }
        let top = count.sorted { $0.value > $1.value }.map { $0.key }
        let palette: [Color] = [Theme.accent, Color(red: 0.30, green: 0.76, blue: 1), Color(red: 0.64, green: 0.90, blue: 0.21)]
        var out: [HomeMix] = []

        for k in 0..<2 {
            let artists = Array(top.dropFirst(k * 3).prefix(3))
            guard !artists.isEmpty else { break }
            let byArtist: (String) -> [Track] = { a in history.filter { $0.artist.hasPrefix(a) } }
            let own = Array(artists.flatMap { Array(byArtist($0).prefix(4)) })
            var radios: [[Track]] = []
            for a in artists.prefix(2) {
                if let seed = byArtist(a).first, let r = try? await engine.radio(seed.id) { radios.append(r) }
            }
            var seen = Set<String>()
            var tracks: [Track] = []
            let lists = [own] + radios
            for i in 0..<(lists.map { $0.count }.max() ?? 0) {
                for l in lists where i < l.count && seen.insert(l[i].id).inserted { tracks.append(l[i]) }
            }
            guard tracks.count >= 5 else { continue }
            let names = artists.prefix(2).joined(separator: ", ")
            out.append(HomeMix(id: "mix\(k)", label: "Mix \(out.count + 1)", detail: artists.count > 2 ? "\(names) and more" : names,
                               tracks: Array(tracks.prefix(40)), color: palette[out.count % palette.count]))
        }

        if let seed = (player.lib.likes.isEmpty ? Array(history.prefix(20)) : player.lib.likes).randomElement(),
           let r = try? await engine.radio(seed.id) {
            let heard = Set(history.map { $0.id })
            let fresh = r.filter { !heard.contains($0.id) }
            if fresh.count >= 5 {
                out.append(HomeMix(id: "discover", label: "Discover", detail: "New songs like \(seed.title)", tracks: fresh, color: palette[2]))
            }
        }
        mixes = out
        mixesLoaded = true
    }

    private func run(_ q: String, heading h: String) {
        busy = true
        error = nil
        results = []
        heading = h
        Task {
            do { results = try await engine.search(q) } catch { self.error = "Search failed: " + String(error.localizedDescription.prefix(160)) }
            busy = false
        }
    }
}
