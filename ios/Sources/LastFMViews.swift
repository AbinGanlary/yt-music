import SwiftUI

/// Which Last.fm song list to show.
enum LFMSource: Hashable {
    case chart
    case country(String)          // a country code like "IN"
    case tag(String)

    var title: String {
        switch self {
        case .chart: return "Top tracks"
        case .country(let c): return "Top in \(LastFM.countryName(c) ?? c)"
        case .tag(let t): return t.prefix(1).uppercased() + t.dropFirst()
        }
    }

    func fetch() async throws -> [LFMTrack] {
        switch self {
        case .chart: return try await LastFM.chart()
        case .country(let c): return try await LastFM.country(c)
        case .tag(let t): return try await LastFM.tag(t)
        }
    }
}

extension SongMatcher {
    /// Matches a long list a few songs at a time, handing each part over as it is ready, so a screen can fill in from the top.
    func resolveInSteps(_ list: [LFMTrack], max: Int = 40, step: Int = 8, _ onPart: ([Track]) -> Void) async {
        var i = 0
        while i < Swift.min(list.count, max) {
            if Task.isCancelled { return }
            let part = Array(list[i..<Swift.min(i + step, list.count)])
            onPart(await resolveAll(part, max: step))
            i += step
        }
    }
}

private func hueColor(_ seed: String, _ shift: Double = 0) -> Color {
    let n = seed.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }
    return Color(hue: (Double(n) / 360 + shift).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.8)
}

/// A square picture (or, when Last.fm has none, a coloured tile with a letter), to be clipped by the caller.
struct ArtTile: View {
    let url: URL?
    let seed: String
    let letter: String

    var body: some View {
        Color.clear.overlay {
            ZStack {
                LinearGradient(colors: [hueColor(seed), hueColor(seed + "x", 0.12).opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let u = url {
                    CachedImage(url: u)
                } else {
                    Text(letter).font(.system(size: 38, weight: .heavy, design: .rounded)).foregroundStyle(Color.white.opacity(0.85))
                }
            }
        }
        .clipped()
    }
}

struct LFMAlbumCard: View {
    let album: LFMAlbum
    var size: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtTile(url: album.image, seed: album.title + album.artist, letter: String(album.title.prefix(1)).uppercased())
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(album.title).font(.subheadline.weight(.semibold)).lineLimit(1).frame(width: size, alignment: .leading)
            Text(album.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).frame(width: size, alignment: .leading)
        }
    }
}

struct LFMArtistCard: View {
    let artist: LFMArtist
    var size: CGFloat = 100

    var body: some View {
        VStack(spacing: 6) {
            ArtTile(url: artist.image, seed: artist.name, letter: String(artist.name.prefix(1)).uppercased())
                .frame(width: size, height: size)
                .clipShape(Circle())
            Text(artist.name).font(.subheadline.weight(.semibold)).lineLimit(1).frame(width: size)
        }
    }
}

struct LFMAlbumShelf: View {
    let title: String
    var note: String? = nil
    let albums: [LFMAlbum]

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.title3.bold())
                    if let n = note { Text(n).font(.caption).foregroundStyle(Theme.muted) }
                }
                .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums, id: \.self) { a in
                            NavigationLink(value: a) { LFMAlbumCard(album: a) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }
}

struct LFMArtistShelf: View {
    let title: String
    let artists: [LFMArtist]

    var body: some View {
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.bold()).padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(artists, id: \.self) { a in
                            NavigationLink(value: a) { LFMArtistCard(artist: a) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }
}

/// Play and Shuffle for a list of songs.
private struct PlayShuffle: View {
    @Environment(PlayerModel.self) private var player
    let tracks: [Track]

    var body: some View {
        if !tracks.isEmpty {
            HStack(spacing: 12) {
                Button { tap(); player.play(tracks[0], in: tracks) } label: {
                    Label("Play", systemImage: "play.fill").font(.subheadline.weight(.bold)).padding(.horizontal, 22).padding(.vertical, 11)
                        .background(Theme.accent, in: Capsule()).foregroundStyle(Color.black)
                }
                Button { tap(); let s = tracks.shuffled(); player.play(s[0], in: s) } label: {
                    Label("Shuffle", systemImage: "shuffle").font(.subheadline.weight(.bold)).padding(.horizontal, 22).padding(.vertical, 11)
                        .background(Theme.surface, in: Capsule())
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// Explore with Last.fm as the source: new albums, charts, top artists and genres (Last.fm tags).
struct LastFMExplore: View {
    @State private var albums: [LFMAlbum] = []
    @State private var artists: [LFMArtist] = []
    @State private var tags: [String] = []
    @State private var error: String?
    @State private var loading = true

    private func chip(_ text: String, _ systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let e = error { Text(e).font(.caption).foregroundStyle(Color.red).padding(.horizontal, 20) }
            if loading && albums.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }

            LFMAlbumShelf(title: "New releases", note: "Popular albums tagged \(Calendar.current.component(.year, from: Date())) on Last.fm", albums: albums)

            VStack(alignment: .leading, spacing: 10) {
                Text("Charts").font(.title3.bold()).padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        NavigationLink(value: LFMSource.chart) { chip("Top tracks", "chart.line.uptrend.xyaxis") }
                        if !EngineHost.loc().isEmpty, let n = LastFM.countryName(EngineHost.loc()) {
                            NavigationLink(value: LFMSource.country(EngineHost.loc())) { chip("Top in \(n)", "mappin.and.ellipse") }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .buttonStyle(.plain)
            }

            LFMArtistShelf(title: "Top artists", artists: artists)

            if !tags.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Genres").font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(tags, id: \.self) { t in
                            NavigationLink(value: LFMSource.tag(t)) {
                                Text(t.prefix(1).uppercased() + t.dropFirst())
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Color.white)
                                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .background(
                                        LinearGradient(colors: [hueColor(t), hueColor(t + "x", 0.12).opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        async let a = LastFM.newAlbums()
        async let r = LastFM.topArtists()
        async let t = LastFM.topTags(limit: 24)
        do { albums = try await a } catch { self.error = error.localizedDescription }
        artists = (try? await r) ?? []
        tags = (try? await t) ?? []
        loading = false
    }
}

/// A Last.fm chart or genre as a song list. The songs are matched on YouTube Music a few at a time, so the list fills in as it goes.
struct LastFMListScreen: View {
    @Environment(PlayerModel.self) private var player
    let source: LFMSource
    @State private var tracks: [Track] = []
    @State private var albums: [LFMAlbum] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            VStack(spacing: 12) {
                Text(source.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text("From Last.fm, matched on YouTube Music").font(.footnote).foregroundStyle(Theme.muted)
                PlayShuffle(tracks: tracks)
                if let e = error { Text(e).font(.caption).foregroundStyle(Color.red).multilineTextAlignment(.center) }
                if loading { ProgressView() }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if !albums.isEmpty {
                LFMAlbumShelf(title: "Albums", albums: albums)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
            }

            SongList(tracks: tracks)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerClearance()
        .task { await load() }
    }

    private func load() async {
        if case .tag(let t) = source { albums = (try? await LastFM.tagAlbums(t, limit: 12)) ?? [] }
        do {
            let list = try await source.fetch()
            await SongMatcher.shared.resolveInSteps(list) { part in
                let have = Set(tracks.map { $0.id })
                tracks.append(contentsOf: part.filter { !have.contains($0.id) })
            }
            if tracks.isEmpty { error = "No songs matched on YouTube Music." }
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

/// A Last.fm album: its cover, and its songs matched on YouTube Music.
struct LastFMAlbumScreen: View {
    let album: LFMAlbum
    @State private var tracks: [Track] = []
    @State private var cover: URL?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            VStack(spacing: 12) {
                ArtTile(url: cover ?? album.image, seed: album.title + album.artist, letter: String(album.title.prefix(1)).uppercased())
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.black.opacity(0.4), radius: 18, y: 10)
                Text(album.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(album.artist).font(.subheadline).foregroundStyle(Theme.muted)
                PlayShuffle(tracks: tracks)
                if let e = error { Text(e).font(.caption).foregroundStyle(Color.red).multilineTextAlignment(.center) }
                if loading { ProgressView() }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            SongList(tracks: tracks)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerClearance()
        .task { await load() }
    }

    private func load() async {
        do {
            guard let info = try await LastFM.albumInfo(artist: album.artist, album: album.title) else {
                error = "Last.fm has no song list for this album."
                loading = false
                return
            }
            cover = info.album.image
            await SongMatcher.shared.resolveInSteps(info.tracks, max: 40) { part in
                let have = Set(tracks.map { $0.id })
                tracks.append(contentsOf: part.filter { !have.contains($0.id) })
            }
            if tracks.isEmpty { error = "No songs matched on YouTube Music." }
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

/// A Last.fm artist: top songs, albums, and similar artists.
struct LastFMArtistScreen: View {
    @Environment(PlayerModel.self) private var player
    let artist: LFMArtist
    @State private var tracks: [Track] = []
    @State private var albums: [LFMAlbum] = []
    @State private var similar: [LFMArtist] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            VStack(spacing: 12) {
                ArtTile(url: artist.image, seed: artist.name, letter: String(artist.name.prefix(1)).uppercased())
                    .frame(width: 160, height: 160)
                    .clipShape(Circle())
                Text(artist.name).font(.title2.bold()).multilineTextAlignment(.center)
                PlayShuffle(tracks: tracks)
                if let first = tracks.first {
                    Button { tap(); player.startRadio(first) } label: {
                        Label("Start radio", systemImage: "dot.radiowaves.left.and.right").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
                if let e = error { Text(e).font(.caption).foregroundStyle(Color.red).multilineTextAlignment(.center) }
                if loading { ProgressView() }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            SongList(tracks: tracks)

            if !albums.isEmpty {
                LFMAlbumShelf(title: "Albums", albums: albums)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
            }
            if !similar.isEmpty {
                LFMArtistShelf(title: "Similar artists", artists: similar)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
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
        async let al = LastFM.artistTopAlbums(artist.name)
        async let sim = LastFM.similarArtists(artist.name)
        do {
            let list = try await LastFM.artistTopTracks(artist.name)
            await SongMatcher.shared.resolveInSteps(list, max: 20) { part in
                let have = Set(tracks.map { $0.id })
                tracks.append(contentsOf: part.filter { !have.contains($0.id) })
            }
            if tracks.isEmpty { error = "No songs matched on YouTube Music." }
        } catch { self.error = error.localizedDescription }
        albums = (try? await al) ?? []
        similar = (try? await sim) ?? []
        loading = false
    }
}

/// Shown on Explore when Last.fm is chosen in Settings but there is no API key yet.
struct LastFMSetupNote: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Last.fm is chosen as the music source, but there is no API key yet. Add a free key in Settings.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            SettingsButton()
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
    }
}
