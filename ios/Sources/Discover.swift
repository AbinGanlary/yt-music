import SwiftUI

// Shared pieces for Home, Mix and Explore: section headers, quick-access tiles, mix cards, the swipeable
// Quick picks grid, loading placeholders, a plain song page, and the list of recently opened albums and playlists.

/// A list of songs to open as its own page (a mix, a chart, a genre's songs).
struct SongsPage: Hashable {
    let title: String
    let tracks: [Track]
}

/// A genre from the Mix tab, opened as its own page.
struct GenrePage: Hashable { let name: String }

struct SongsScreen: View {
    @Environment(PlayerModel.self) private var player
    let page: SongsPage
    var body: some View {
        List { SongList(tracks: page.tracks) }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .miniPlayerClearance()
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !page.tracks.isEmpty {
                        Button { tap(); player.play(page.tracks[0], in: page.tracks) } label: { Label("Play all", systemImage: "play.fill") }
                    }
                }
            }
    }
}

/// A section title with an optional small line above it and something on the right ("See all", a button).
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                if let s = subtitle { Text(s).font(.footnote).foregroundStyle(Theme.muted) }
                Text(title).font(.title2.bold())
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 20)
    }
}
extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

/// "See all" in a section header.
struct SeeAll<Value: Hashable>: View {
    let value: Value
    var body: some View {
        NavigationLink(value: value) { Text("See all").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted) }
            .buttonStyle(.plain)
    }
}

/// A small outlined pill button ("Play all", "Global").
struct PillButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    var body: some View {
        Button { tap(); action() } label: {
            HStack(spacing: 5) {
                if let i = icon { Image(systemName: i).font(.caption.weight(.bold)) }
                Text(title).font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

/// A round accent play button, drawn on cards.
struct PlayDot: View {
    var size: CGFloat = 36
    let action: () -> Void
    var body: some View {
        Button { tap(); action() } label: {
            Image(systemName: "play.fill").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(Color.black)
                .offset(x: size * 0.03)
                .frame(width: size, height: size)
                .background(Theme.accent, in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play")
    }
}

/// A grey block that gently pulses, shown where content is still loading.
struct Placeholder: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var radius: CGFloat = 12
    @State private var dim = false
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.surface)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .opacity(dim ? 0.45 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true } }
    }
}

/// A row of loading cards, the size of a shelf.
struct ShelfPlaceholder: View {
    var size: CGFloat = 140
    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    Placeholder(width: size, height: size)
                    Placeholder(width: size * 0.8, height: 12, radius: 4)
                    Placeholder(width: size * 0.5, height: 10, radius: 4)
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// Rows of loading songs.
struct RowsPlaceholder: View {
    var count = 4
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 12) {
                    Placeholder(width: 48, height: 48, radius: 8)
                    VStack(alignment: .leading, spacing: 6) {
                        Placeholder(width: 170, height: 13, radius: 4)
                        Placeholder(width: 110, height: 11, radius: 4)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

/// One tile of Home's quick-access grid: a square picture on the left, the name on the right.
struct JumpTile<Art: View>: View {
    let title: String
    @ViewBuilder var art: () -> Art
    var body: some View {
        HStack(spacing: 10) {
            art().frame(width: 54, height: 54).clipped()
            Text(title).font(.footnote.weight(.bold)).lineLimit(2).foregroundStyle(Color.primary)
            Spacer(minLength: 4)
        }
        .frame(height: 54)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A gradient square with a symbol, for tiles that have no cover (Liked songs, Downloads).
struct SymbolArt: View {
    let symbol: String
    let colors: [Color]
    var body: some View {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay { Image(systemName: symbol).font(.title3.weight(.bold)).foregroundStyle(.white) }
    }
}

/// A personal mix on Home: built from songs you play a lot, and the radios of their artists.
struct HomeMix: Identifiable, Hashable {
    let id: String
    let label: String          // "Mix 1", "Discover"
    let detail: String         // "Neon Harbor, Lila Moreno and more"
    let tracks: [Track]
    let color: Color
}

/// The square card for a mix: the cover of its first song, with a coloured band and the mix's name.
struct MixCard: View {
    @Environment(PlayerModel.self) private var player
    let mix: HomeMix
    var size: CGFloat = 150
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                if let t = mix.tracks.first { Cover(track: t, radius: 0) } else { mix.color }
                Text(mix.label).font(.subheadline.weight(.heavy)).foregroundStyle(Color.black)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .background(mix.color)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(mix.detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(2).frame(width: size, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(); if let f = mix.tracks.first { player.play(f, in: mix.tracks) } }
        .contextMenu {
            Button { if let f = mix.tracks.first { player.play(f, in: mix.tracks) } } label: { Label("Play", systemImage: "play.fill") }
            Button { let s = mix.tracks.shuffled(); if let f = s.first { player.play(f, in: s) } } label: { Label("Shuffle", systemImage: "shuffle") }
        }
    }
}

/// Songs in columns of four that page sideways, like YouTube Music's Quick picks.
struct QuickPicksGrid: View {
    @Environment(PlayerModel.self) private var player
    let tracks: [Track]
    var rows = 4

    var body: some View {
        let columns = stride(from: 0, to: tracks.count, by: rows).map { Array(tracks[$0..<min($0 + rows, tracks.count)]) }
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(columns.indices, id: \.self) { c in
                    VStack(spacing: 10) {
                        ForEach(columns[c]) { t in row(t) }
                        Spacer(minLength: 0)
                    }
                    .containerRelativeFrame(.horizontal) { w, _ in w - 56 }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 20, for: .scrollContent)
    }

    private func row(_ t: Track) -> some View {
        HStack(spacing: 12) {
            Cover(track: t, radius: 8).frame(width: 48, height: 48)
                .overlay { if player.current == t && player.isPlaying { Image(systemName: "waveform").foregroundStyle(.white) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(t.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(); player.play(t, in: tracks) }
        .contextMenu {
            Button { player.startRadio(t) } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
            Button { player.startParty(from: t) } label: { Label("Start a party", systemImage: "party.popper") }
            Button { player.playNext(t) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { player.addToQueue(t) } label: { Label("Add to queue", systemImage: "text.append") }
            Button { player.toggleLike(t) } label: {
                Label(player.liked.contains(t.id) ? "Remove from liked" : "Like", systemImage: player.liked.contains(t.id) ? "heart.slash" : "heart")
            }
        }
    }
}

/// Albums and playlists you opened lately, newest first, for Home's quick-access grid.
enum RecentPages {
    private static let key = "recentPages"
    static func all() -> [Coll] {
        guard let d = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([Coll].self, from: d) else { return [] }
        return list
    }
    static func add(_ c: Coll) {
        guard c.kind != "liked" else { return }
        let list = [c] + all().filter { $0.id != c.id }
        if let d = try? JSONEncoder().encode(Array(list.prefix(8))) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// Plays an album or playlist without opening it.
@MainActor
func playCollection(_ c: Coll, engine: EngineHost, player: PlayerModel, shuffle: Bool = false) async {
    let kind = ["album", "playlist", "artist"].contains(c.kind) ? c.kind : "playlist"
    guard let page: PageData = try? await engine.get("/api/\(kind)/\(EngineHost.enc(c.id))") else { player.notify("Couldn't open \(c.title)"); return }
    var list = (page.tracks ?? []).compactMap { Track($0) }
    if shuffle { list.shuffle() }
    guard let first = list.first else { player.notify("No songs in \(c.title)"); return }
    player.play(first, in: list)
}

/// A stable colour for a name (genres, moods).
func nameColor(_ s: String, brightness: Double = 0.75) -> Color {
    let n = s.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }
    return Color(hue: Double(n) / 360, saturation: 0.7, brightness: brightness)
}

/// Which tab is showing, so Home's search button can switch to Explore and open its search field.
@Observable
final class TabRouter {
    var tab = 0
    var focusSearch = false
}
