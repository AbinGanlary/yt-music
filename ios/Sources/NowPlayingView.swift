import SwiftUI
import AVKit

struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerModel
    @State private var page = 0                       // 0 cover, 1 lyrics, 2 queue

    var body: some View {
        let t = player.current
        ZStack {
            Theme.bg.ignoresSafeArea()
            t.art.opacity(0.45).blur(radius: 70).ignoresSafeArea()
            LinearGradient(colors: [Theme.bg.opacity(0.35), Theme.bg.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Capsule().fill(Color.primary.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 8)

                Picker("", selection: $page) {
                    Text("Song").tag(0)
                    Text("Lyrics").tag(1)
                    Text("Queue").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 28)

                Group {
                    switch page {
                    case 1: LyricsView()
                    case 2: QueueView()
                    default:
                        Cover(track: t, radius: 18)
                            .aspectRatio(1, contentMode: .fit)
                            .shadow(color: Color.black.opacity(0.5), radius: 30, y: 18)
                            .scaleEffect(player.isPlaying ? 1 : 0.9)
                            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
                            .padding(.horizontal, 28)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.title).font(.title2.bold()).lineLimit(1)
                        Text(t.artist).font(.body).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    Button { tap(.medium); player.dislike(t) } label: {
                        Image(systemName: player.lib.isDisliked(t) ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.title3)
                            .foregroundStyle(player.lib.isDisliked(t) ? Theme.accent : Theme.muted)
                            .frame(width: 44, height: 48)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not interested")
                    Button { tap(.medium); player.toggleLike(t) } label: {
                        Image(systemName: player.liked.contains(t.id) ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(player.liked.contains(t.id) ? Theme.accent : Color.primary)
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 28)

                ScrubberView()
                    .padding(.horizontal, 28)

                HStack(spacing: 24) {
                    Button { tap(); player.toggleShuffle() } label: {
                        Image(systemName: "shuffle").font(.title3).foregroundStyle(player.shuffle ? Theme.accent : Theme.muted)
                    }
                    .accessibilityLabel("Shuffle")
                    Button { tap(); player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                    Button { tap(.medium); player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 72))
                    }
                    Button { tap(); player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                    Button { tap(); player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == 2 ? "repeat.1" : "repeat").font(.title3).foregroundStyle(player.repeatMode == 0 ? Theme.muted : Theme.accent)
                    }
                    .accessibilityLabel("Repeat")
                }
                .buttonStyle(.plain)

                HStack(spacing: 22) {
                    Menu {
                        ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { s in
                            Button { player.setSpeed(s) } label: {
                                if player.speed == s { Label(String(format: "%g×", s), systemImage: "checkmark") } else { Text(String(format: "%g×", s)) }
                            }
                        }
                    } label: { Label(String(format: "%g×", player.speed), systemImage: "speedometer") }

                    Menu {
                        Button("Off") { player.setSleep(minutes: nil) }
                        Button("15 minutes") { player.setSleep(minutes: 15) }
                        Button("30 minutes") { player.setSleep(minutes: 30) }
                        Button("60 minutes") { player.setSleep(minutes: 60) }
                        Button("End of this song") { player.setSleep(minutes: 0) }
                    } label: { Label(player.sleepLabel ?? "Sleep", systemImage: "moon.zzz") }

                    Button { tap(); player.startRadio(t) } label: { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                    Button { player.saveToFiles(t) } label: { Label("Save", systemImage: "square.and.arrow.up") }
                    AirPlayButton().frame(width: 30, height: 30)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.primary.opacity(0.8))

                Text(player.status)
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
            }
        }
    }
}

struct LyricsView: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var time: PlaybackClock

    var body: some View {
        Group {
            switch player.lyricsState {
            case .idle, .loading:
                VStack { Spacer(); ProgressView(); Text("Looking for lyrics…").font(.footnote).foregroundStyle(Theme.muted).padding(.top, 6); Spacer() }
                    .frame(maxWidth: .infinity)
            case .none:
                VStack(spacing: 6) {
                    Spacer()
                    Text("No lyrics for this song").font(.headline)
                    Text("Lyrics show here and follow the song line by line when they are available.").font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.horizontal, 36)
            case .ready(let l):
                if let lines = l.lines, !lines.isEmpty, l.hasTimestamps == true { synced(lines, source: l.source) }
                else { plain(l) }
            }
        }
        .task(id: player.current.id) { await player.loadLyrics() }
    }

    private func activeIndex(_ lines: [LyricLine]) -> Int {
        var idx = 0
        for (i, l) in lines.enumerated() { if let s = l.start, s <= time.elapsed + 0.15 { idx = i } }
        return idx
    }

    private func synced(_ lines: [LyricLine], source: String?) -> some View {
        let active = activeIndex(lines)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title2.bold())
                            .foregroundStyle(i == active ? Color.primary : Color.primary.opacity(0.32))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { if let s = line.start { tap(); player.seekTo(seconds: s) } }
                            .id(i)
                    }
                    if let s = source { Text(s).font(.caption).foregroundStyle(Theme.muted).padding(.top, 12) }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 40)
            }
            .onChange(of: active) { i in withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(i, anchor: .center) } }
        }
    }

    private func plain(_ l: Lyrics) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text(l.lyrics ?? "").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                if let s = l.source { Text(s).font(.caption).foregroundStyle(Theme.muted) }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
    }
}

struct QueueView: View {
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        List {
            ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t, playing: i == player.index)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .onTapGesture { tap(); player.jump(to: i) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if i != player.index {
                            Button(role: .destructive) { tap(.medium); player.removeFromQueue(at: i) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// The seek bar and the two times. It is the only part of Now Playing that redraws as the song plays.
struct ScrubberView: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var time: PlaybackClock
    @State private var scrubbing: Double?

    var body: some View {
        let total = max(1, time.duration)
        let fraction = scrubbing ?? min(1, time.elapsed / total)
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { fraction }, set: { scrubbing = $0 }),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing, let s = scrubbing { player.seek(s); scrubbing = nil; tap() }
                }
            )
            .tint(Theme.accent)
            HStack {
                Text(clock(fraction * total))
                Spacer()
                Text("-" + clock((1 - fraction) * total))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.muted)
        }
    }
}

/// The system AirPlay / output picker.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.label.withAlphaComponent(0.8)
        v.activeTintColor = UIColor.tintColor
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
