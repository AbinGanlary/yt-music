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
    var note: String?                      // what the decks are doing ("Mixing · filter", "Getting the song ready…")
    var nextReady = false                  // the next song is downloaded and analysed
    var bpm: Double?                       // the current song's tempo, when it could be measured
    var sure = false                       // its beats were steady enough to mix on
}

/// A kind of party: what it is called and what is searched for it.
struct PartyVibe: Identifiable, Hashable {
    let name: String
    let query: String
    let symbol: String
    var id: String { name }
}

/// Mostly English, with the Indian party favourites after them.
let partyVibes: [PartyVibe] = [
    PartyVibe(name: "Pop hits", query: "Pop party hits", symbol: "star.fill"),
    PartyVibe(name: "Dance & EDM", query: "EDM dance party anthems", symbol: "waveform"),
    PartyVibe(name: "House", query: "House music party", symbol: "house.fill"),
    PartyVibe(name: "Hip-hop", query: "Hip hop party songs", symbol: "mic.fill"),
    PartyVibe(name: "R&B", query: "R&B party hits", symbol: "heart.fill"),
    PartyVibe(name: "2000s throwback", query: "2000s party hits", symbol: "opticaldisc.fill"),
    PartyVibe(name: "80s & 90s", query: "80s 90s party hits", symbol: "radio.fill"),
    PartyVibe(name: "Latin", query: "Latin reggaeton party hits", symbol: "sun.max.fill"),
    PartyVibe(name: "Afrobeats", query: "Afrobeats party hits", symbol: "globe.europe.africa.fill"),
    PartyVibe(name: "K-pop", query: "K-pop dance hits", symbol: "sparkles"),
    PartyVibe(name: "Workout", query: "Gym workout songs", symbol: "figure.run"),
    PartyVibe(name: "Bollywood dance", query: "Bollywood dance party songs", symbol: "music.mic"),
    PartyVibe(name: "Punjabi", query: "Punjabi party songs", symbol: "flame.fill"),
    PartyVibe(name: "Desi hip-hop", query: "Desi hip hop", symbol: "music.quarternote.3"),
    PartyVibe(name: "Wedding", query: "Wedding sangeet dance songs", symbol: "party.popper.fill"),
]

/// The Party card on Home and Mix.
struct PartyBanner: View {
    @Environment(PlayerModel.self) private var player
    var body: some View {
        Button { tap(); player.showParty = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "party.popper.fill").font(.system(size: 30)).foregroundStyle(.white)
                    .frame(width: 54, height: 54).background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Party mode").font(.headline.weight(.heavy))
                    Text(player.party != nil ? "Your party is on. Tap to open it." : "Your songs or a vibe, mixed like a DJ.").font(.footnote).opacity(0.9)
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
    }
}

/// Party mode: choose the vibe, then a full-screen view of the set as it plays.
struct PartyView: View {
    @Environment(EngineHost.self) private var engine
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @AppStorage("partyVibes") private var storedVibes = "Pop hits|Dance & EDM"
    @AppStorage("partyClip") private var clip = 75.0
    @AppStorage("partyMinutes") private var minutes = 60
    @AppStorage("mixStyle") private var mixStyle = "auto"
    @AppStorage("partyDJView") private var djView = false
    @State private var building = false
    @State private var progress = ""
    @State private var seeds: [Track] = []
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searchTask: Task<Void, Never>?

    private var chosen: [String] { storedVibes.split(separator: "|").map(String.init) }

    var body: some View {
        ZStack {
            if player.party != nil {
                if djView { DJView(djView: $djView, close: { dismiss() }) } else { PartyLive(djView: $djView, close: { dismiss() }) }
            } else if player.partyStarting {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Lining up the party…").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            } else {
                setup
            }
        }
        .animation(.easeOut(duration: 0.3), value: player.party != nil)
        .onAppear { ScreenOrientation.set(landscape: djView && player.party != nil) }
        .onChange(of: djView) { _, on in ScreenOrientation.set(landscape: on && player.party != nil) }
        .onChange(of: player.party != nil) { _, on in ScreenOrientation.set(landscape: on && djView) }
        .onDisappear { ScreenOrientation.set(landscape: false) }
    }

    // MARK: - setup

    private var setup: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    seedSection
                    VStack(alignment: .leading, spacing: 10) {
                        Text(seeds.isEmpty ? "What's the vibe?" : "Add a vibe (optional)").font(.title2.bold())
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
                        Text("How should songs change?").font(.title2.bold())
                        Picker("Mix style", selection: $mixStyle) {
                            Text("Auto").tag("auto"); Text("Smooth").tag("smooth"); Text("Club").tag("club"); Text("Hype").tag("hype")
                        }
                        .pickerStyle(.segmented)
                        Text(mixStyleNote).font(.footnote).foregroundStyle(Theme.muted)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How much of each song?").font(.title2.bold())
                        Picker("Clip", selection: $clip) {
                            Text("Hooks (60 s)").tag(60.0); Text("Hooks (90 s)").tag(90.0); Text("Whole songs").tag(0.0)
                        }
                        .pickerStyle(.segmented)
                        Text(clip > 0 ? "Each song comes in at its chorus and, about \(Int(clip)) seconds later (at the end of a phrase), is mixed into the next: same tempo, beats lined up, basses swapped on the drop. Tap Keep playing to hear a song to the end."
                                      : "Each song comes in at its chorus, plays to near its end and is mixed into the next one, beat-matched.")
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
                    .background(canStart ? Theme.accent : Color.gray, in: Capsule())
                    .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .disabled(!canStart || building)
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
            .navigationTitle("Party mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private var canStart: Bool { !chosen.isEmpty || !seeds.isEmpty }

    private var mixStyleNote: String {
        switch mixStyle {
        case "smooth": "Long blends, bass swaps and filters; reverb and echo when tempos are far apart."
        case "club": "Bass swaps and filters most of the time, with echoes, loop rolls and clean cuts."
        case "hype": "Loop rolls, brakes, backspins and drop cuts, for big moments."
        default: "A mix of everything, picked to suit each pair of songs."
        }
    }

    // MARK: - starting from your own songs

    private var seedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start from your songs").font(.title2.bold())
            Text("Pick up to three songs. The party starts with them and keeps going with songs like them.").font(.footnote).foregroundStyle(Theme.muted)
            if !seeds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seeds) { t in
                            HStack(spacing: 8) {
                                Cover(track: t, radius: 6).frame(width: 30, height: 30)
                                Text(t.title).font(.footnote.weight(.semibold)).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                                Button { tap(); seeds.removeAll { $0.id == t.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                                    .accessibilityLabel("Remove \(t.title)")
                            }
                            .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 5)
                            .background(Theme.surface, in: Capsule())
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search a song", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty { Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) } }
            }
            .padding(.horizontal, 12).frame(height: 44)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: query) { _, q in search(q) }
            ForEach(Array(results.prefix(5))) { t in
                let picked = seeds.contains { $0.id == t.id }
                Button {
                    tap()
                    if picked { seeds.removeAll { $0.id == t.id } } else if seeds.count < 3 { seeds.append(t); query = ""; results = [] } else { player.notify("Up to three songs") }
                } label: {
                    HStack(spacing: 10) {
                        Cover(track: t, radius: 6).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(t.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: picked ? "checkmark.circle.fill" : "plus.circle").font(.title3).foregroundStyle(picked ? Theme.accent : Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if query.isEmpty && seeds.isEmpty && !player.lib.likes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(player.lib.likes.prefix(8))) { t in
                            Button { tap(); if seeds.count < 3 { seeds.append(t) } } label: {
                                Label(t.title, systemImage: "heart.fill").font(.caption.weight(.semibold)).lineLimit(1)
                                    .padding(.horizontal, 10).padding(.vertical, 7).background(Theme.surface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func search(_ q: String) {
        searchTask?.cancel()
        let text = q.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let found = (try? await engine.search(text)) ?? []
            if !Task.isCancelled { results = found }
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
        for t in seeds {
            progress = "Finding songs like \(t.title)…"
            let like = ((try? await engine.radio(t.id)) ?? []).filter { $0.id != t.id }
            lists.append(like.filter { !disliked.contains($0.id) && $0.seconds <= 420 })
        }
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
        var seenID = Set(seeds.map { $0.id }), seenTitle = Set(seeds.map { Self.titleKey($0.title) })
        var set: [Track] = seeds
        for i in 0..<(lists.map { $0.count }.max() ?? 0) {
            for l in lists where i < l.count {
                let t = l[i], key = Self.titleKey(t.title)
                if seenID.insert(t.id).inserted && seenTitle.insert(key).inserted { set.append(t) }
            }
            if set.count >= want { break }
        }
        guard !set.isEmpty else { player.notify("Couldn't find songs for this party"); return }
        let title = (seeds.map { $0.title } + chosen).prefix(3).joined(separator: " + ")
        player.startParty(Array(set.prefix(want)), title: title, clip: clip)
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
    @Binding var djView: Bool
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
                    ViewSwitch(djView: $djView)
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
                    HStack(spacing: 6) {
                        chip(hookLabel(p))
                        if let bpm = p?.bpm, p?.startedFor == t.id { chip("\(Int(bpm)) BPM", icon: p?.sure == true ? "metronome.fill" : "metronome") }
                    }
                    .padding(.top, 4)
                    if let note = p?.note { Text(note).font(.caption.weight(.semibold)).opacity(0.85).padding(.top, 2) }
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

    private func chip(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 4)
        .background(.white.opacity(0.15), in: Capsule())
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
                HStack {
                    Text("UP NEXT").font(.caption2.weight(.heavy)).tracking(1.4).opacity(0.7)
                    Spacer()
                    Label(player.party?.nextReady == true ? "Next ready" : "Getting the next song…",
                          systemImage: player.party?.nextReady == true ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.caption2.weight(.semibold)).opacity(0.8)
                }
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
                    .onTapGesture { tap(); if player.queue.indices.contains(player.index + 1), player.queue[player.index + 1].id == n.id { player.next() } else { player.play(n) } }
                }
            }
            .padding(14)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 22)
        }
    }
}
