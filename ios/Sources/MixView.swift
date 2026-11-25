import SwiftUI

private let presets = ["Lo-fi", "Tamil hip-hop", "90s Bollywood", "K-pop", "Indie", "Rock", "Jazz", "EDM", "Classical", "Devotional", "Punjabi", "Telugu hits", "Workout", "Acoustic", "Focus"]

/// The songs (and, from YouTube Music, playlists) found for one genre.
struct MixGenre {
    var songs: [Track]
    var playlists: [Coll]
}

/// Finds the songs and playlists for one genre: YouTube Music, or Last.fm's tag top tracks when Last.fm is the source.
@MainActor
func loadGenre(_ g: String, engine: EngineHost) async -> MixGenre? {
    if LastFM.active {
        guard let list = try? await LastFM.tag(g.lowercased(), limit: 30) else { return nil }
        return MixGenre(songs: await SongMatcher.shared.resolveAll(list, max: 20), playlists: [])
    }
    guard let d: GenreData = try? await engine.get("/api/genre?q=\(EngineHost.enc(g))") else { return nil }
    return MixGenre(songs: d.songs.compactMap { Track($0) }, playlists: d.playlists)
}

/// Mix tab: "Your mix" (every genre blended), a station built from artists you pick, and your genres as cards.
struct MixView: View {
    @Environment(EngineHost.self) private var engine
    @Environment(PlayerModel.self) private var player
    @AppStorage("mixGenres") private var stored = ""
    @State private var loaded: [String: MixGenre] = [:]
    @AppStorage("musicSource") private var musicSource = "youtube"
    @State private var adding = false
    @State private var newName = ""
    @State private var editing = false
    @State private var building = false

    private var genres: [String] { stored.split(separator: "|").map(String.init) }

    private func add(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !genres.contains(n) else { return }
        stored = (genres + [n]).joined(separator: "|")
    }

    private func remove(_ name: String) {
        stored = genres.filter { $0 != name }.joined(separator: "|")
        loaded[name] = nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if genres.isEmpty { empty } else { hero }
                    PartyBanner()
                    builderCard
                    if !genres.isEmpty { genreGrid; moreChips }
                }
                .padding(.vertical, 8)
                .padding(.bottom, 140)
            }
            .background(Theme.bg)
            .navigationTitle("Mix")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a genre")
                    SettingsButton()
                }
            }
            .alert("Add a genre or mood", isPresented: $adding) {
                TextField("For example Lo-fi", text: $newName)
                Button("Add") { add(newName); newName = "" }
                Button("Cancel", role: .cancel) { newName = "" }
            }
            .sheet(isPresented: $building) { StationBuilder().environment(engine).environment(player) }
            .navigationDestination(for: Coll.self) { CollectionScreen(coll: $0) }
            .navigationDestination(for: GenrePage.self) { GenreScreen(name: $0.name, preloaded: loaded[$0.name]) }
            .task(id: stored + "|" + musicSource + "|" + LastFM.key) { await loadMissing() }
            .onChange(of: musicSource) { _, _ in loaded = [:] }
        }
    }

    // MARK: - pieces

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text("Build your mixes").font(.title3.bold())
            Text("Add genres, moods or styles. Each one gets its own songs and playlists, and Your mix blends them all.")
                .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            FlowChips(items: presets) { add($0) }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    private var mixName: String {
        let g = genres
        if g.count > 4 { return g.prefix(3).joined(separator: ", ") + " and \(g.count - 3) more" }
        if g.count > 1 { return g.dropLast().joined(separator: ", ") + " and " + g.last! }
        return g.first ?? ""
    }

    /// The big "Your mix" card: every genre blended, with Play, Shuffle and Radio.
    private var hero: some View {
        let songs = blended()
        let covers = genres.compactMap { loaded[$0]?.songs.first }.prefix(3)
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR MIX").font(.caption.weight(.heavy)).tracking(1.4).opacity(0.85)
                Spacer(minLength: 40)
                Text(mixName).font(.title3.weight(.heavy)).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
                Text(songs.isEmpty ? "Finding songs…" : "\(songs.count) songs, blended and shuffled").font(.footnote).opacity(0.85)
                HStack(spacing: 10) {
                    Button { tap(); play(songs) } label: {
                        Label("Play", systemImage: "play.fill").font(.subheadline.weight(.bold))
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(.white, in: Capsule()).foregroundStyle(Color.black)
                    }
                    circleButton("shuffle", "Shuffle") { play(songs.shuffled()) }
                    circleButton("dot.radiowaves.left.and.right", "Start radio") {
                        if let t = songs.randomElement() { player.startRadio(t) }
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                ForEach(Array(covers.enumerated()), id: \.offset) { i, t in
                    Cover(track: t, radius: 12).frame(width: 74, height: 74)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                        .rotationEffect(.degrees(Double(8 - i * 10)))
                        .offset(x: CGFloat(-i * 28), y: CGFloat(i * 8))
                }
            }
            .frame(width: 74, height: 74)
        }
        .padding(18)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Theme.accent, Color(red: 0.49, green: 0.23, blue: 0.93), Color(red: 0.16, green: 0.06, blue: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .padding(.horizontal, 20)
    }

    private func circleButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { tap(); action() } label: {
            Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 40, height: 40).background(.black.opacity(0.22), in: Circle())
        }
        .accessibilityLabel(label)
    }

    /// "Build a station": opens the artist picker.
    private var builderCard: some View {
        let faces = uniqueArtists(player.lib.history).prefix(3)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Build a station")
            Button { tap(); building = true } label: {
                HStack(spacing: 14) {
                    HStack(spacing: -14) {
                        ForEach(Array(faces.enumerated()), id: \.offset) { _, t in
                            Cover(track: t, radius: 25).frame(width: 50, height: 50)
                                .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                        }
                        Image(systemName: "plus").font(.title3.weight(.bold)).foregroundStyle(Theme.accent)
                            .frame(width: 50, height: 50).background(Theme.bg, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pick up to 5 artists").font(.subheadline.weight(.bold))
                        Text("and get one station that mixes them").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
        }
    }

    private var genreGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Your genres") {
                Button(editing ? "Done" : "Edit") { tap(); withAnimation(.easeOut(duration: 0.2)) { editing.toggle() } }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(editing ? Theme.accent : Theme.muted)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(genres, id: \.self) { g in
                    GenreCard(name: g, data: loaded[g], editing: editing,
                              play: { if let d = loaded[g] { play(d.songs) } else { player.notify("Still finding songs…") } },
                              remove: { withAnimation { remove(g) } })
                }
                Button { tap(); adding = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.title2.weight(.semibold))
                        Text("Add a genre").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 112)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder private var moreChips: some View {
        let more = presets.filter { !genres.contains($0) }
        if !more.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Try adding")
                FlowChips(items: Array(more.prefix(9))) { add($0) }.padding(.horizontal, 20)
            }
        }
    }

    // MARK: - logic

    private func loadMissing() async {
        for g in genres where loaded[g] == nil {
            if let d = await loadGenre(g, engine: engine) { loaded[g] = d }
        }
    }

    /// Songs from every loaded genre, interleaved; the first few stay in order, the rest are shuffled.
    private func blended() -> [Track] {
        let lists = genres.compactMap { loaded[$0] }.map { $0.songs }
        var seen = Set<String>()
        var out: [Track] = []
        for i in 0..<(lists.map { $0.count }.max() ?? 0) {
            for l in lists where i < l.count && !seen.contains(l[i].id) { seen.insert(l[i].id); out.append(l[i]) }
        }
        return out
    }

    private func play(_ list: [Track]) {
        guard !list.isEmpty else { player.notify("Still finding songs…"); return }
        let mix = Array(list.prefix(6)) + list.dropFirst(6).shuffled()
        player.play(mix[0], in: mix)
    }
}

/// One song per artist, newest first (faces for the station card).
func uniqueArtists(_ tracks: [Track]) -> [Track] {
    var seen = Set<String>()
    return tracks.filter { t in
        let a = t.artist.components(separatedBy: ", ").first ?? t.artist
        return seen.insert(a).inserted
    }
}

/// A colour card for one genre: two covers, the name, how much was found, and a play button.
struct GenreCard: View {
    let name: String
    let data: MixGenre?
    let editing: Bool
    let play: () -> Void
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationLink(value: GenrePage(name: name)) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [nameColor(name, brightness: 0.7), nameColor(name + "·", brightness: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let songs = data?.songs, !songs.isEmpty {
                        ZStack(alignment: .topLeading) {
                            Cover(track: songs[0], radius: 8).frame(width: 52, height: 52)
                            if songs.count > 1 { Cover(track: songs[1], radius: 8).frame(width: 52, height: 52).offset(x: 30, y: 10) }
                        }
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, 30).padding(.top, 10)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.headline.weight(.heavy)).lineLimit(1)
                        Text(detail).font(.caption2).opacity(0.85).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .padding(.trailing, 40)
                }
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            if !editing { PlayDot(size: 34, action: play).padding(10) }
        }
        .overlay(alignment: .topLeading) {
            if editing {
                Button { tap(); remove() } label: {
                    Image(systemName: "minus.circle.fill").font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .accessibilityLabel("Remove \(name)")
            }
        }
    }

    private var detail: String {
        guard let d = data else { return "Finding songs…" }
        let p = d.playlists.count
        return "\(d.songs.count) songs" + (p > 0 ? " · \(p) playlists" : "")
    }
}

/// One genre's songs and playlists.
struct GenreScreen: View {
    @Environment(EngineHost.self) private var engine
    @Environment(PlayerModel.self) private var player
    let name: String
    let preloaded: MixGenre?
    @State private var data: MixGenre?

    var body: some View {
        let d = data ?? preloaded
        List {
            if let d {
                if !d.playlists.isEmpty { Shelf(title: "Playlists", items: d.playlists).homeRow(top: 6, bottom: 12) }
                SectionHeader(title: "Songs").homeRow(top: 4, bottom: 2)
                SongList(tracks: d.songs)
            } else {
                RowsPlaceholder(count: 8).homeRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .miniPlayerClearance()
        .navigationTitle(name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let songs = d?.songs, !songs.isEmpty {
                    Button { tap(); let s = songs.shuffled(); player.play(s[0], in: s) } label: { Label("Shuffle", systemImage: "shuffle") }
                }
            }
        }
        .task { if preloaded == nil { data = await loadGenre(name, engine: engine) } }
    }
}

/// Pick up to five artists; the station mixes their songs and the radios of their best-known songs.
struct StationBuilder: View {
    @Environment(EngineHost.self) private var engine
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tasteArtists") private var tasteArtists = ""
    @State private var query = ""
    @State private var found: [Coll] = []
    @State private var chosen: [Coll] = []
    @State private var starting = false

    private var suggestions: [Coll] {
        Taste.artists(tasteArtists).map { Coll(kind: "artist", id: $0.id, title: $0.name, subtitle: nil, thumbnail: nil) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !chosen.isEmpty {
                    Section("Your station") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(chosen) { c in
                                    Button { tap(); chosen.removeAll { $0.id == c.id } } label: {
                                        HStack(spacing: 6) {
                                            Text(c.title).font(.subheadline.weight(.semibold))
                                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Theme.accent.opacity(0.2), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                Section(query.isEmpty ? (suggestions.isEmpty ? "Search for an artist" : "Your artists") : "Artists") {
                    ForEach(query.isEmpty ? suggestions : found) { c in
                        let on = chosen.contains { $0.id == c.id }
                        Button {
                            tap()
                            if on { chosen.removeAll { $0.id == c.id } } else if chosen.count < 5 { chosen.append(c) } else { player.notify("Up to 5 artists") }
                        } label: {
                            HStack(spacing: 12) {
                                RemoteSquare(url: c.url).frame(width: 44, height: 44).clipShape(Circle())
                                Text(c.title).foregroundStyle(Color.primary)
                                Spacer()
                                Image(systemName: on ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(on ? Theme.accent : Theme.muted).font(.title3)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search artists")
            .task(id: query) { await search() }
            .navigationTitle("Build a station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if starting { ProgressView() } else {
                        Button("Play") { Task { await start() } }.disabled(chosen.isEmpty).fontWeight(.bold)
                    }
                }
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { found = []; return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }
        found = (try? await engine.get("/api/artists/search?q=\(EngineHost.enc(q))", as: [Coll].self)) ?? []
    }

    /// Each artist's top songs plus the radio of their first song, interleaved so no artist plays twice in a row.
    private func start() async {
        starting = true
        defer { starting = false }
        var lists: [[Track]] = []
        for a in chosen {
            guard let page: PageData = try? await engine.get("/api/artist/\(EngineHost.enc(a.id))") else { continue }
            let own = (page.tracks ?? []).compactMap { Track($0) }
            var list = Array(own.prefix(5))
            if let seed = own.first, let r = try? await engine.radio(seed.id) { list += r.prefix(15) }
            lists.append(list)
        }
        var seen = Set<String>()
        var out: [Track] = []
        for i in 0..<(lists.map { $0.count }.max() ?? 0) {
            for l in lists where i < l.count && seen.insert(l[i].id).inserted { out.append(l[i]) }
        }
        guard let first = out.first else { player.notify("Couldn't find songs for these artists"); return }
        player.play(first, in: out)
        player.notify("Station: " + chosen.map { $0.title }.joined(separator: ", "))
        dismiss()
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
