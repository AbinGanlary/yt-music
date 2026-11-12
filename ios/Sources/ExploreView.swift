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

private func moodColor(_ s: String) -> Color {
    let n = s.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }
    return Color(hue: Double(n) / 360, saturation: 0.7, brightness: 0.75)
}

struct ExploreView: View {
    @EnvironmentObject var engine: EngineHost
    @State private var data: ExploreData?
    @State private var charts: ChartsData?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if let e = error { Text(e).font(.caption).foregroundStyle(Color.red).padding(.horizontal, 20) }
                    if data == nil && error == nil { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
                    Shelf(title: "New releases", items: data?.newReleases ?? [])
                    Shelf(title: "Charts", items: charts?.playlists ?? [])
                    Shelf(title: "Top artists", items: charts?.artists ?? [])
                    ForEach(data?.moods ?? [], id: \.self) { sec in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(sec.section).font(.title3.bold())
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(sec.items, id: \.self) { m in
                                    NavigationLink(value: m) {
                                        Text(m.title)
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(Color.white)
                                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                                            .padding(.horizontal, 14)
                                            .background(
                                                LinearGradient(colors: [moodColor(m.title), moodColor(m.title + "x").opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing),
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
                .padding(.vertical, 8)
                .padding(.bottom, 140)
            }
            .background(Theme.bg)
            .navigationTitle("Explore")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { SettingsButton() } }
            .navigationDestination(for: Coll.self) { CollectionScreen(coll: $0) }
            .navigationDestination(for: MoodItem.self) { MoodScreen(mood: $0) }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        do {
            data = try await engine.get("/api/explore")
            error = nil
        } catch { self.error = "Explore failed: " + String(error.localizedDescription.prefix(160)) }
        if let c: ChartsData = try? await engine.get("/api/charts?country=ZZ") { charts = c }
    }
}

struct MoodScreen: View {
    @EnvironmentObject var engine: EngineHost
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
    @EnvironmentObject var engine: EngineHost
    @EnvironmentObject var player: PlayerModel
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
        .task { await load() }
    }

    private func load() async {
        let kind = ["album", "playlist", "artist"].contains(coll.kind) ? coll.kind : "playlist"
        do {
            page = try await engine.get(coll.kind == "liked" ? "/api/liked" : "/api/\(kind)/\(EngineHost.enc(coll.id))")
            error = nil
        } catch { self.error = "Couldn't open this: " + String(error.localizedDescription.prefix(140)) }
    }
}
