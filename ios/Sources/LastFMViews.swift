import SwiftUI

/// Which Last.fm list to show.
enum LFMSource: Hashable {
    case chart
    case country(String)          // a country code like "IN"
    case tag(String)

    var title: String {
        switch self {
        case .chart: return "Last.fm top tracks"
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

/// A Last.fm chart or tag as a song list. The songs are matched on YouTube Music a few at a time, so the list fills in as it goes.
struct LastFMListScreen: View {
    @Environment(PlayerModel.self) private var player
    let source: LFMSource
    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            VStack(spacing: 12) {
                Text(source.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text("From Last.fm, matched on YouTube Music").font(.footnote).foregroundStyle(Theme.muted)
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
            let list = try await source.fetch()
            var i = 0
            while i < min(list.count, 40) {                                   // eight at a time, so the first songs show quickly
                let part = Array(list[i..<min(i + 8, list.count)])
                let found = await SongMatcher.shared.resolveAll(part, max: 8)
                let have = Set(tracks.map { $0.id })
                tracks.append(contentsOf: found.filter { !have.contains($0.id) })
                i += 8
            }
            if tracks.isEmpty { error = "No songs matched on YouTube Music." }
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

/// Explore: Last.fm charts and popular tags (or a note on how to switch it on).
struct LastFMExploreSection: View {
    @AppStorage("lastfmKey") private var key = ""
    @State private var tags: [String] = []

    private func chip(_ text: String, _ systemImage: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let s = systemImage { Image(systemName: s) }
            Text(text)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last.fm").font(.title3.bold()).padding(.horizontal, 20)
            if key.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    Text("Charts, tags and similar songs from Last.fm. Add a free API key in Settings to switch it on.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    SettingsButton()
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        NavigationLink(value: LFMSource.chart) { chip("Top tracks", "chart.line.uptrend.xyaxis") }
                        if let c = EngineHost.loc().nilIfEmpty, let name = LastFM.countryName(c) {
                            NavigationLink(value: LFMSource.country(c)) { chip("Top in \(name)", "mappin.and.ellipse") }
                        }
                        ForEach(tags, id: \.self) { t in
                            NavigationLink(value: LFMSource.tag(t)) { chip(t.prefix(1).uppercased() + t.dropFirst()) }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: key) {
            guard LastFM.isOn else { tags = []; return }
            tags = (try? await LastFM.topTags()) ?? []
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
