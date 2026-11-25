import SwiftUI

/// A square (or round, for artists) card for an album, playlist or artist.
struct CollCard: View {
    let c: Coll
    var size: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteSquare(url: c.url)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: c.kind == "artist" ? size / 2 : 12, style: .continuous))
            Text(c.title).font(.subheadline.weight(.semibold)).lineLimit(1).frame(width: size, alignment: c.kind == "artist" ? .center : .leading)
            if let s = c.subtitle, !s.isEmpty, c.kind != "artist" {
                Text(s).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).frame(width: size, alignment: .leading)
            }
        }
    }
}

struct Shelf: View {
    let title: String
    let items: [Coll]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.bold()).padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { c in
                            NavigationLink(value: c) { CollCard(c: c) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }
}

struct ExploreView: View {
    @Environment(EngineHost.self) private var engine
    @Environment(PlayerModel.self) private var player
    @Environment(TabRouter.self) private var router
    @State private var data: ExploreData?
    @State private var charts: ChartsData?
    @State private var error: String?
    @AppStorage("musicSource") private var musicSource = "youtube"        // "youtube" or "lastfm" (Settings)
    @AppStorage("lastfmKey") private var lastfmKey = ""
    @AppStorage("recentSearches") private var recentStore = ""
    @State private var query = ""
    @State private var searching = false
    @State private var suggestions: [String] = []
    @State private var searched = ""
    @State private var songs: [Track] = []
    @State private var artists: [Coll] = []
    @State private var searchBusy = false
    @State private var top: [Track] = []
    @State private var topLocal = false
    @State private var release = 0
    private var lfm: Bool { musicSource == "lastfm" }
    private var hasKey: Bool { !lastfmKey.trimmingCharacters(in: .whitespaces).isEmpty }
    private var recent: [String] { recentStore.split(separator: "|").map(String.init) }
    private var showingResults: Bool { !searched.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if showingResults { resultsList } else { browse }
            }
            .background(Theme.bg)
            .navigationTitle("Explore")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { SettingsButton() } }
            .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
            .searchSuggestions {
                ForEach(query.isEmpty ? recent : suggestions, id: \.self) { s in
                    Button { query = s; submit(s) } label: { Label(s, systemImage: query.isEmpty ? "clock" : "magnifyingglass") }
                }
            }
            .onSubmit(of: .search) { submit(query) }
            .task(id: query) { await loadSuggestions() }
            .onChange(of: query) { _, q in                                 // clearing the search box goes back to browsing
                if q.trimmingCharacters(in: .whitespaces).isEmpty { searched = ""; songs = []; artists = [] }
            }
            .task(id: router.focusSearch) {                                // Home's search button
                if router.focusSearch { searching = true; router.focusSearch = false }
            }
            .navigationDestination(for: Coll.self) { CollectionScreen(coll: $0) }
            .navigationDestination(for: MoodItem.self) { MoodScreen(mood: $0) }
            .navigationDestination(for: SongsPage.self) { SongsScreen(page: $0) }
            .navigationDestination(for: LFMSource.self) { LastFMListScreen(source: $0) }
            .navigationDestination(for: LFMAlbum.self) { LastFMAlbumScreen(album: $0) }
            .navigationDestination(for: LFMArtist.self) { LastFMArtistScreen(artist: $0) }
            .task(id: musicSource) { await load() }
            .task(id: topLocal) { await loadTop() }
        }
    }

    // MARK: - search

    private var resultsList: some View {
        List {
            if searchBusy {
                RowsPlaceholder(count: 6).homeRow()
            } else if songs.isEmpty && artists.isEmpty {
                Text("No results for “\(searched)”. Try another spelling or fewer words.").font(.subheadline).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 20).homeRow()
            }
            if !artists.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Artists")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(artists) { c in NavigationLink(value: c) { CollCard(c: c, size: 96) }.buttonStyle(.plain) }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .homeRow(top: 6, bottom: 10)
            }
            if !songs.isEmpty {
                SectionHeader(title: "Songs") { PillButton(title: "Play all", icon: "play.fill") { player.play(songs[0], in: songs) } }
                    .homeRow(top: 6, bottom: 2)
                SongList(tracks: songs)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .miniPlayerClearance()
    }

    private func submit(_ q: String) {
        let text = q.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        recentStore = ([text] + recent.filter { $0 != text }).prefix(8).joined(separator: "|")
        searched = text
        searchBusy = true
        songs = []
        artists = []
        Task {
            let found = try? await engine.search(text)
            let people = try? await engine.get("/api/artists/search?q=\(EngineHost.enc(text))", as: [Coll].self)
            guard searched == text else { return }
            songs = found ?? []
            artists = Array((people ?? []).prefix(8))
            searchBusy = false
        }
    }

    private func loadSuggestions() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { suggestions = []; return }
        try? await Task.sleep(nanoseconds: 250_000_000)             // wait for a pause in typing
        if Task.isCancelled { return }
        if let s: [String] = try? await engine.get("/api/suggest?q=\(EngineHost.enc(q))") { suggestions = Array(s.prefix(8)) }
    }

    // MARK: - browsing

    private var browse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let e = error { Text(e).font(.caption).foregroundStyle(Color.red).padding(.horizontal, 20) }
                if lfm {
                    if hasKey { LastFMExplore() } else { LastFMSetupNote() }
                } else {
                    releases
                    topSongs
                    if charts == nil { ShelfPlaceholder() } else {
                        Shelf(title: "Charts", items: charts?.playlists ?? [])
                        Shelf(title: "Top artists", items: charts?.artists ?? [])
                    }
                    if data == nil && error == nil {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(0..<6, id: \.self) { _ in Placeholder(height: 92, radius: 10) }
                        }
                        .padding(.horizontal, 20)
                    }
                    ForEach(data?.moods ?? [], id: \.self) { sec in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(sec.section).font(.title2.bold()).padding(.horizontal, 20)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(sec.items, id: \.self) { m in
                                    NavigationLink(value: m) { BrowseTile(title: m.title) }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.bottom, 140)
        }
        .refreshable { await load(); await loadTop() }
    }

    /// New releases as large cards that page sideways.
    @ViewBuilder private var releases: some View {
        let items = Array((data?.newReleases ?? []).prefix(8))
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "New releases")
            if items.isEmpty {
                Placeholder(height: 150, radius: 20).padding(.horizontal, 20)
            } else {
                TabView(selection: $release) {
                    ForEach(items.indices, id: \.self) { i in
                        ReleaseCard(c: items[i]) { Task { await playCollection(items[i], engine: engine, player: player) } }
                            .padding(.horizontal, 20)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 150)
                HStack(spacing: 5) {
                    ForEach(items.indices, id: \.self) { i in
                        Capsule().fill(i == release ? Color.primary : Color.primary.opacity(0.25)).frame(width: i == release ? 16 : 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.2), value: release)
            }
        }
    }

    /// The most played songs right now, numbered: worldwide, or in your country.
    private var topSongs: some View {
        let loc = EngineHost.loc()
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Top songs", subtitle: topLocal ? "In \(Locale.current.localizedString(forRegionCode: loc) ?? loc)" : "Worldwide") {
                HStack(spacing: 10) {
                    if !loc.isEmpty {
                        PillButton(title: topLocal ? loc : "Global", icon: "globe") { topLocal.toggle() }
                    }
                    if !top.isEmpty { SeeAll(value: SongsPage(title: "Top songs", tracks: top)) }
                }
            }
            if top.isEmpty { RowsPlaceholder(count: 5) }
            ForEach(Array(top.prefix(5).enumerated()), id: \.element.id) { n, t in
                HStack(spacing: 12) {
                    Text("\(n + 1)").font(.headline.weight(.heavy).monospacedDigit()).frame(width: 22)
                    Cover(track: t, radius: 8).frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(t.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if player.current == t && player.isPlaying { Image(systemName: "waveform").foregroundStyle(Theme.accent) }
                }
                .padding(.horizontal, 20)
                .contentShape(Rectangle())
                .onTapGesture { tap(); player.play(t, in: top) }
                .contextMenu {
                    Button { player.startRadio(t) } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
                    Button { player.startParty(from: t) } label: { Label("Start a party", systemImage: "party.popper") }
                    Button { player.playNext(t) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button { player.toggleLike(t) } label: { Label("Like", systemImage: "heart") }
                }
            }
        }
    }

    private func load() async {
        if lfm { return }
        do {
            data = try await engine.get("/api/explore")
            error = nil
        } catch { self.error = "Explore failed: " + String(error.localizedDescription.prefix(160)) }
        if let c: ChartsData = try? await engine.get("/api/charts?country=ZZ") { charts = c }
    }

    private func loadTop() async {
        if lfm { return }
        let loc = EngineHost.loc()
        let country = topLocal && !loc.isEmpty ? loc : "ZZ"
        if let raw: [RawTrack] = try? await engine.get("/api/trending?country=\(country)") { top = raw.compactMap { Track($0) } }
    }
}

/// A large new-release card: the cover, the title, and a play button.
struct ReleaseCard: View {
    let c: Coll
    let play: () -> Void
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
        NavigationLink(value: c) {
            HStack(spacing: 14) {
                RemoteSquare(url: c.url).frame(width: 118, height: 118)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text("NEW RELEASE").font(.caption2.weight(.heavy)).tracking(1.2).opacity(0.85)
                    Text(c.title).font(.title3.weight(.heavy)).lineLimit(2)
                    if let s = c.subtitle, !s.isEmpty { Text(s).font(.footnote).opacity(0.85).lineLimit(1) }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 146)
            .background(
                LinearGradient(colors: [nameColor(c.title, brightness: 0.45), nameColor(c.title + "·", brightness: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        PlayDot(size: 38, action: play).padding(14)
        }
    }
}

/// A colour tile for a mood or genre, with a tilted square in the corner.
struct BrowseTile: View {
    let title: String
    var body: some View {
        ZStack(alignment: .topLeading) {
            nameColor(title)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [nameColor(title + "x", brightness: 0.95), nameColor(title + "y", brightness: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { Image(systemName: "music.note").font(.title3.weight(.bold)).foregroundStyle(.white.opacity(0.85)) }
                .frame(width: 58, height: 58)
                .rotationEffect(.degrees(24))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                .offset(x: 10, y: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            Text(title).font(.headline.weight(.heavy)).foregroundStyle(.white).lineLimit(2).padding(12)
        }
        .frame(height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MoodScreen: View {
    @Environment(EngineHost.self) private var engine
    let mood: MoodItem
    @State private var items: [Coll] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            if !loaded { ProgressView().padding(.top, 60) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                ForEach(items) { c in
                    NavigationLink(value: c) { CollCard(c: c, size: 150) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 140)
        }
        .background(Theme.bg)
        .navigationTitle(mood.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let p = EngineHost.enc(mood.params)
            items = (try? await engine.get("/api/mood?params=\(p)", as: [Coll].self)) ?? []
            loaded = true
        }
    }
}

/// An album, playlist or artist page.
struct CollectionScreen: View {
    @Environment(EngineHost.self) private var engine
    @Environment(PlayerModel.self) private var player
    let coll: Coll
    @State private var page: PageData?
    @State private var error: String?

    private var tracks: [Track] { (page?.tracks ?? []).compactMap { Track($0) } }

    var body: some View {
        let list = tracks
        List {
            VStack(spacing: 14) {
                RemoteSquare(url: sizedURL(page?.thumbnail ?? coll.thumbnail, 600))
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: coll.kind == "artist" ? 100 : 14, style: .continuous))
                .shadow(color: Color.black.opacity(0.4), radius: 18, y: 10)
                Text(page?.title ?? coll.title).font(.title2.bold()).multilineTextAlignment(.center)
                if let s = page?.subtitle ?? coll.subtitle, !s.isEmpty { Text(s).font(.subheadline).foregroundStyle(Theme.muted) }
                if let m = page?.meta, !m.isEmpty { Text(m).font(.caption).foregroundStyle(Theme.muted) }
                if !list.isEmpty {
                    HStack(spacing: 12) {
                        Button { tap(); player.play(list[0], in: list) } label: {
                            Label("Play", systemImage: "play.fill").font(.subheadline.weight(.bold)).padding(.horizontal, 22).padding(.vertical, 11)
                                .background(Theme.accent, in: Capsule()).foregroundStyle(Color.black)
                        }
                        Button { tap(); let s = list.shuffled(); player.play(s[0], in: s) } label: {
                            Label("Shuffle", systemImage: "shuffle").font(.subheadline.weight(.bold)).padding(.horizontal, 22).padding(.vertical, 11)
                                .background(Theme.surface, in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                }
                if coll.kind != "liked" {
                    HStack(spacing: 12) {
                        Button {
                            tap()
                            let on = player.lib.toggleSaved(coll)
                            player.notify(on ? (coll.kind == "artist" ? "Following" : "Saved to library") : (coll.kind == "artist" ? "Unfollowed" : "Removed from library"))
                        } label: {
                            Label(player.lib.isSaved(coll) ? (coll.kind == "artist" ? "Following" : "In library") : (coll.kind == "artist" ? "Follow" : "Save to library"),
                                  systemImage: player.lib.isSaved(coll) ? "checkmark" : "plus")
                                .font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 9)
                                .background(Theme.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                        }
                        if let rid = page?.radioVideoId, let first = list.first(where: { $0.id == rid }) ?? list.first {
                            Button { tap(); player.startRadio(first) } label: {
                                Label("Start radio", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 9)
                                    .background(Theme.surface, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if let e = error { Text(e).font(.caption).foregroundStyle(Color.red) }
                if page == nil && error == nil { ProgressView() }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if !list.isEmpty { SongList(tracks: list) }

            if let albums = page?.albums, !albums.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(albums) { a in NavigationLink(value: a) { CollCard(c: a, size: 130) }.buttonStyle(.plain) }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Albums").font(.title3.bold()).foregroundStyle(Color.primary).textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerClearance()
        .task { await load() }
    }

    private func load() async {
        let kind = ["album", "playlist", "artist"].contains(coll.kind) ? coll.kind : "playlist"
        do {
            page = try await engine.get(coll.kind == "liked" ? "/api/liked" : "/api/\(kind)/\(EngineHost.enc(coll.id))")
            error = nil
            RecentPages.add(Coll(kind: coll.kind, id: coll.id, title: coll.title, subtitle: coll.subtitle, thumbnail: coll.thumbnail ?? page?.thumbnail))
        } catch { self.error = "Couldn't open this: " + String(error.localizedDescription.prefix(140)) }
    }
}
