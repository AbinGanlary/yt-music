import SwiftUI

/// Where a song's hook is, from the engine: "chorus" (from the synced lyrics), "replayed" (YouTube's Most replayed),
/// "guess" (about a third of the way in) or "none".
struct HookInfo: Decodable, Equatable {
    let start: Double
    let source: String
}

/// Party mode while it runs.
struct PartyState: Equatable {
    var title: String
    var clip: Double                       // seconds of each song; 0 = whole songs
    var keep = false                       // the current song plays to its end
    var startedFor: String?                // the song whose hook has been handled
    var hookStart: Double = 0
    var hookSource = ""
    var hooks: [String: HookInfo] = [:]
}

/// A kind of party: what it is called and what is searched for it.
struct PartyVibe: Identifiable, Hashable {
    let name: String
    let query: String
    let symbol: String
    var id: String { name }
}

let partyVibes: [PartyVibe] = [
    PartyVibe(name: "Bollywood dance", query: "Bollywood dance party songs", symbol: "sparkles"),
    PartyVibe(name: "Punjabi party", query: "Punjabi party songs", symbol: "flame.fill"),
    PartyVibe(name: "Hindi hits", query: "Hindi party hits", symbol: "star.fill"),
    PartyVibe(name: "Wedding", query: "Wedding sangeet dance songs", symbol: "heart.fill"),
    PartyVibe(name: "Tamil kuthu", query: "Tamil kuthu songs", symbol: "music.quarternote.3"),
    PartyVibe(name: "Telugu mass", query: "Telugu mass dance songs", symbol: "bolt.fill"),
    PartyVibe(name: "Garba", query: "Garba dandiya songs", symbol: "circle.hexagongrid.fill"),
    PartyVibe(name: "Desi hip-hop", query: "Desi hip hop", symbol: "mic.fill"),
    PartyVibe(name: "Retro", query: "90s Bollywood party songs", symbol: "opticaldisc.fill"),
    PartyVibe(name: "Workout", query: "Gym workout songs", symbol: "figure.run"),
    PartyVibe(name: "English pop", query: "English party pop hits", symbol: "globe"),
    PartyVibe(name: "EDM", query: "EDM party anthems", symbol: "waveform"),
]

/// The Party card on Home and Mix.
struct PartyBanner: View {
    @Environment(EngineHost.self) private var engine
    @Environment(PlayerModel.self) private var player
    @State private var open = false
    var body: some View {
        Button { tap(); open = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "party.popper.fill").font(.system(size: 30)).foregroundStyle(.white)
                    .frame(width: 54, height: 54).background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Party mode").font(.headline.weight(.heavy))
                    Text("Pick the vibe. Every song starts at the hook.").font(.footnote).opacity(0.9)
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.white.opacity(0.8))
            }
            .padding(14)
            .background(
                LinearGradient(colors: [Color(red: 1, green: 0.36, blue: 0.54), Color(red: 0.98, green: 0.45, blue: 0.09), Color(red: 0.49, green: 0.23, blue: 0.93)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .fullScreenCover(isPresented: $open) { PartyView().environment(engine).environment(player).environment(player.time) }
    }
}

/// Party mode: choose the vibe, then a full-screen view of the set as it plays.
struct PartyView: View {
    @Environment(EngineHost.self) private var engine
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @AppStorage("partyVibes") private var storedVibes = "Bollywood dance|Punjabi party"
    @AppStorage("partyClip") private var clip = 75.0
    @AppStorage("partyMinutes") private var minutes = 60
    @State private var building = false
    @State private var progress = ""

    private var chosen: [String] { storedVibes.split(separator: "|").map(String.init) }

    var body: some View {
        ZStack {
            if player.party != nil { PartyLive(close: { dismiss() }) } else { setup }
        }
        .animation(.easeOut(duration: 0.3), value: player.party != nil)
    }

    // MARK: - setup

    private var setup: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("What's the vibe?").font(.title2.bold())
                        Text("Pick up to three. Your liked songs that fit come first.").font(.footnote).foregroundStyle(Theme.muted)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            vibeTile(PartyVibe(name: "Your favourites", query: "", symbol: "heart.circle.fill"))
                            ForEach(partyVibes) { vibeTile($0) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How long?").font(.title2.bold())
                        Picker("Length", selection: $minutes) {
                            Text("30 min").tag(30); Text("1 hour").tag(60); Text("2 hours").tag(120); Text("All night").tag(240)
                        }
                        .pickerStyle(.segmented)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How much of each song?").font(.title2.bold())
                        Picker("Clip", selection: $clip) {
                            Text("Hooks (60 s)").tag(60.0); Text("Hooks (90 s)").tag(90.0); Text("Whole songs").tag(0.0)
                        }
                        .pickerStyle(.segmented)
                        Text(clip > 0 ? "Each song starts at its chorus and fades into the next after \(Int(clip)) seconds. Tap Keep playing to hear a song to the end."
                                      : "Each song starts at its chorus and plays to the end.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .background(Theme.bg)
            .safeAreaInset(edge: .bottom) {
                Button { Task { await build() } } label: {
                    HStack(spacing: 8) {
                        if building { ProgressView().tint(.black) } else { Image(systemName: "party.popper.fill") }
                        Text(building ? progress : "Start the party").font(.headline.weight(.heavy))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(chosen.isEmpty ? Color.gray : Theme.accent, in: Capsule())
                    .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .disabled(chosen.isEmpty || building)
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
            .navigationTitle("Party mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func vibeTile(_ v: PartyVibe) -> some View {
        let on = chosen.contains(v.name)
        return Button {
            tap()
            var list = chosen
            if on { list.removeAll { $0 == v.name } } else if list.count < 3 { list.append(v.name) } else { player.notify("Up to three vibes") }
            storedVibes = list.joined(separator: "|")
        } label: {
            HStack(spacing: 10) {
                Image(systemName: v.symbol).font(.title3).frame(width: 28)
                Text(v.name).font(.subheadline.weight(.bold)).lineLimit(1)
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark.circle.fill") }
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 12).frame(height: 54)
            .background(on ? AnyShapeStyle(LinearGradient(colors: [nameColor(v.name, brightness: 0.8), nameColor(v.name + "·", brightness: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Theme.surface),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - building the set

    /// Songs for each chosen vibe (its songs plus its first two playlists), the liked ones first, interleaved so the
    /// vibes take turns; no disliked songs, no long versions, no repeats of the same song.
    private func build() async {
        building = true
        defer { building = false }
        let liked = player.liked, disliked = player.lib.dislikedIDs
        let perSong = clip > 0 ? clip + 2 : 210
        let want = max(15, Int(Double(minutes * 60) / perSong))
        var lists: [[Track]] = []
        for name in chosen {
            progress = "Finding \(name)…"
            var list: [Track] = []
            if name == "Your favourites" {
                list = player.lib.likes.shuffled()
            } else if let v = partyVibes.first(where: { $0.name == name }),
                      let d: GenreData = try? await engine.get("/api/genre?q=\(EngineHost.enc(v.query))") {
                list = d.songs.compactMap { Track($0) }
                for c in d.playlists.prefix(2) {
                    if let page: PageData = try? await engine.get("/api/playlist/\(EngineHost.enc(c.id))") {
                        list += (page.tracks ?? []).compactMap { Track($0) }
                    }
                }
                list = list.filter { liked.contains($0.id) }.shuffled() + list.filter { !liked.contains($0.id) }.shuffled()
            }
            lists.append(list.filter { !disliked.contains($0.id) && $0.seconds <= 420 })
        }
        var seenID = Set<String>(), seenTitle = Set<String>()
        var set: [Track] = []
        for i in 0..<(lists.map { $0.count }.max() ?? 0) {
            for l in lists where i < l.count {
                let t = l[i], key = Self.titleKey(t.title)
                if seenID.insert(t.id).inserted && seenTitle.insert(key).inserted { set.append(t) }
            }
            if set.count >= want { break }
        }
        guard !set.isEmpty else { player.notify("Couldn't find songs for this party"); return }
        player.startParty(Array(set.prefix(want)), title: chosen.joined(separator: " + "), clip: clip)
    }

    /// "Kala Chashma (From “Baar Baar Dekho”)" and "Kala Chashma" are the same song.
    static func titleKey(_ s: String) -> String {
        let base = s.components(separatedBy: "(").first ?? s
        return base.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// The full-screen view while the party plays.
struct PartyLive: View {
    @Environment(PlayerModel.self) private var player
    @Environment(PlaybackClock.self) private var clock
    let close: () -> Void
    @State private var pulse = false

    var body: some View {
        let t = player.current
        let p = player.party
        ZStack {
            LinearGradient(colors: t.colors + [Color.black], startPoint: pulse ? .topLeading : .top, endPoint: pulse ? .bottomTrailing : .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: pulse)
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    Button { close() } label: { Image(systemName: "chevron.down").font(.title3.weight(.bold)) }
                    Spacer()
                    VStack(spacing: 1) {
                        Text("PARTY MODE").font(.caption2.weight(.heavy)).tracking(1.5).opacity(0.8)
                        Text(p?.title ?? "").font(.footnote.weight(.semibold)).lineLimit(1)
                    }
                    Spacer()
                    Button { tap(); player.stopParty(); close() } label: { Text("End").font(.subheadline.weight(.bold)) }
                }
                .padding(.horizontal, 22)

                Cover(track: t, radius: 24)
                    .frame(width: 300, height: 300)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                    .scaleEffect(player.isPlaying ? 1 : 0.92)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: player.isPlaying)
                    .padding(.top, 8)

                VStack(spacing: 4) {
                    Text(t.title).font(.title2.weight(.heavy)).lineLimit(1)
                    Text(t.artist).font(.body).opacity(0.8).lineLimit(1)
                    Text(hookLabel(p)).font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.15), in: Capsule()).padding(.top, 4)
                }
                .padding(.horizontal, 24)

                clipBar(p)

                HStack(spacing: 34) {
                    roundButton("arrow.counterclockwise", "From the start") { player.fromTheStart() }
                    Button { tap(); player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30, weight: .bold))
                            .frame(width: 76, height: 76).background(.white, in: Circle()).foregroundStyle(Color.black)
                    }
                    roundButton("forward.fill", "Skip") { player.next() }
                }
                if let p, p.clip > 0 {
                    Button { tap(); player.keepPlaying() } label: {
                        Label(p.keep ? "Playing to the end" : "Keep playing", systemImage: p.keep ? "checkmark" : "infinity")
                            .font(.subheadline.weight(.bold)).padding(.horizontal, 18).padding(.vertical, 10)
                            .background(.white.opacity(p.keep ? 0.3 : 0.15), in: Capsule())
                    }
                    .disabled(p.keep)
                }
                upNext
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.top, 10)
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
    }

    private func hookLabel(_ p: PartyState?) -> String {
        guard let p, p.startedFor == player.current.id else { return "Finding the hook…" }
        switch p.hookSource {
        case "chorus": return "Started at the chorus"
        case "replayed": return "Started at the most replayed part"
        case "guess": return "Started a third of the way in"
        default: return "Playing from the start"
        }
    }

    /// Progress through this song's clip (or the whole song).
    private func clipBar(_ p: PartyState?) -> some View {
        let start = p?.hookStart ?? 0
        let clipLen = (p?.clip ?? 0) > 0 && !(p?.keep ?? false) ? p!.clip : max(1, clock.duration - start)
        let f = max(0, min(1, (clock.elapsed - start) / clipLen))
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white).frame(width: g.size.width * f)
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 32)
    }

    private func roundButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { tap(); action() } label: {
            Image(systemName: icon).font(.title3.weight(.bold)).frame(width: 54, height: 54).background(.white.opacity(0.15), in: Circle())
        }
        .accessibilityLabel(label)
    }

    @ViewBuilder private var upNext: some View {
        let next = Array(player.queue.dropFirst(player.index + 1).prefix(3))
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("UP NEXT").font(.caption2.weight(.heavy)).tracking(1.4).opacity(0.7)
                ForEach(next) { n in
                    HStack(spacing: 10) {
                        Cover(track: n, radius: 6).frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(n.title).font(.footnote.weight(.semibold)).lineLimit(1)
                            Text(n.artist).font(.caption2).opacity(0.7).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { tap(); player.play(n) }
                }
            }
            .padding(14)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 22)
        }
    }
}
