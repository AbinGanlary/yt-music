import SwiftUI
import QuartzCore

private let deckColors = [Color(red: 0.2, green: 0.8, blue: 1), Color(red: 1, green: 0.4, blue: 0.55)]

/// Party | DJ, at the top of the party player.
struct ViewSwitch: View {
    @Binding var djView: Bool
    var body: some View {
        HStack(spacing: 2) {
            segment("Party", "party.popper.fill", !djView) { djView = false }
            segment("DJ", "slider.horizontal.3", djView) { djView = true }
        }
        .padding(3)
        .background(.white.opacity(0.14), in: Capsule())
    }
    private func segment(_ title: String, _ icon: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { tap(); action() } label: {
            Label(title, systemImage: icon).font(.caption.weight(.bold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Color.white : Color.clear, in: Capsule())
                .foregroundStyle(on ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

/// The DJ view of a party: two decks, their waveforms, the crossfader, and live effects. Best in landscape.
struct DJView: View {
    @Environment(PlayerModel.self) private var player
    @Binding var djView: Bool
    let close: () -> Void
    @AppStorage("mixStyle") private var mixStyle = "auto"

    var body: some View {
        let live = player.dj.live
        GeometryReader { g in
            let wide = g.size.width > g.size.height
            Group {
                if wide {
                    VStack(spacing: 6) {
                        topBar
                        WaveStrip(deck: live.decks[0], color: deckColors[0]).frame(height: 44)
                        WaveStrip(deck: live.decks[1], color: deckColors[1]).frame(height: 44)
                        HStack(alignment: .top, spacing: 10) {
                            DeckPanel(deck: live.decks[0], number: 1)
                            MixerPanel(live: live).frame(width: 210)
                            DeckPanel(deck: live.decks[1], number: 2)
                        }
                        Spacer(minLength: 0)
                        PadRow(live: live)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .padding(.top, 6)
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            topBar
                            Label("Turn your phone sideways for the full DJ view", systemImage: "rectangle.landscape.rotate")
                                .font(.caption.weight(.semibold)).opacity(0.7)
                            WaveStrip(deck: live.decks[0], color: deckColors[0]).frame(height: 44)
                            WaveStrip(deck: live.decks[1], color: deckColors[1]).frame(height: 44)
                            DeckPanel(deck: live.decks[0], number: 1)
                            MixerPanel(live: live)
                            DeckPanel(deck: live.decks[1], number: 2)
                            PadRow(live: live)
                        }
                        .padding(14)
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.07).ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { close() } label: { Image(systemName: "chevron.down").font(.headline.weight(.bold)) }
                .accessibilityLabel("Hide")
            ViewSwitch(djView: $djView)
            Spacer()
            Menu {
                Picker("Mix style", selection: $mixStyle) {
                    Text("Auto").tag("auto"); Text("Smooth").tag("smooth"); Text("Club").tag("club"); Text("Hype").tag("hype")
                }
            } label: {
                Label("Style: \(mixStyle.capitalized)", systemImage: "dial.medium").font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.12), in: Capsule())
            }
            .onChange(of: mixStyle) { _, _ in player.dj.replan() }
            AirPlayButton().frame(width: 30, height: 30).accessibilityLabel("Speakers and AirPlay")
            Button { tap(); player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.headline)
                    .frame(width: 36, height: 30).background(.white.opacity(0.12), in: Capsule())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { tap(); player.next() } label: {
                Image(systemName: "forward.fill").font(.headline).frame(width: 36, height: 30).background(.white.opacity(0.12), in: Capsule())
            }
            .accessibilityLabel("Skip")
            Button { tap(); player.stopParty(); close() } label: { Text("End").font(.subheadline.weight(.bold)) }
        }
        .buttonStyle(.plain)
    }
}

/// Where a deck is right now, carried forward between the 20-a-second updates so things move smoothly.
private func livePos(_ d: DJLive.DeckView) -> Double {
    d.playing ? d.pos + (CACurrentMediaTime() - d.at) * d.rate : d.pos
}

/// A deck's waveform scrolling past the playhead, with its beats, the chorus and the mix point.
struct WaveStrip: View {
    let deck: DJLive.DeckView
    let color: Color
    var body: some View {
        TimelineView(.animation(paused: !deck.playing)) { _ in
            Canvas { gc, size in
                let w = size.width, h = size.height
                let span = 12.0
                let pos = livePos(deck)
                let x: (Double) -> CGFloat = { t in CGFloat((t - pos) / span + 0.5) * w }
                gc.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(.white.opacity(0.05)))
                if let wave = deck.wave {
                    let first = max(0, Int((pos - span / 2) / wave.step)), last = min(wave.amp.count - 1, Int((pos + span / 2) / wave.step))
                    if first <= last {
                        let bw = max(1, w / CGFloat(span / wave.step) - 0.5)
                        for i in first...last {
                            let t = Double(i) * wave.step
                            let a = CGFloat(wave.amp[i]) * (h / 2 - 3)
                            let played = t < pos
                            let c = wave.bass[i] > 0.55 ? color : Color.white
                            gc.fill(Path(CGRect(x: x(t), y: h / 2 - a, width: bw, height: a * 2)), with: .color(c.opacity(played ? 0.35 : 0.85)))
                        }
                    }
                }
                if let anchor = deck.anchor, let per = deck.period, per > 0.2 {
                    var k = ((pos - span / 2 - anchor) / per).rounded(.up)
                    while anchor + k * per < pos + span / 2 {
                        let t = anchor + k * per
                        let bar = Int(k) % 4 == 0
                        gc.fill(Path(CGRect(x: x(t), y: 0, width: bar ? 1.5 : 0.75, height: bar ? h : h * 0.25)), with: .color(.white.opacity(bar ? 0.4 : 0.25)))
                        k += 1
                    }
                }
                var marks: [(Double, String, Color)] = []
                if deck.hook > 0 { marks.append((deck.hook, "CHORUS", .yellow)) }
                if let m = deck.mixAt { marks.append((m, "MIX", .green)) }
                for (t, label, c) in marks where abs(t - pos) < span / 2 {
                    gc.fill(Path(CGRect(x: x(t) - 1, y: 0, width: 2, height: h)), with: .color(c))
                    gc.draw(Text(label).font(.system(size: 9, weight: .heavy)).foregroundColor(c), at: CGPoint(x: x(t) + 4, y: 7), anchor: .leading)
                }
                gc.fill(Path(CGRect(x: w / 2 - 1, y: 0, width: 2, height: h)), with: .color(.white))
                if deck.track == nil {
                    gc.draw(Text("Next song loading…").font(.caption).foregroundColor(.white.opacity(0.5)), at: CGPoint(x: w / 2, y: h / 2))
                }
            }
        }
    }
}

/// A deck: the spinning record, the song, its tempo and level meters.
struct DeckPanel: View {
    let deck: DJLive.DeckView
    let number: Int
    var body: some View {
        let color = deckColors[number - 1]
        HStack(spacing: 10) {
            if number == 2 { meters(color) }
            Platter(deck: deck, color: color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("DECK \(number)").font(.caption2.weight(.heavy)).foregroundStyle(color)
                    Text(deck.onAir ? "ON AIR" : deck.track == nil ? "EMPTY" : deck.playing ? "MIXING IN" : "CUED")
                        .font(.system(size: 9, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(deck.onAir ? color.opacity(0.35) : .white.opacity(0.12), in: Capsule())
                }
                Text(deck.track?.title ?? "—").font(.subheadline.weight(.bold)).lineLimit(1)
                Text(deck.track?.artist ?? " ").font(.caption).opacity(0.7).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(deck.bpm.map { String(format: "%.1f", $0) } ?? "–").font(.title3.monospacedDigit().weight(.heavy))
                    Text("BPM").font(.caption2.weight(.bold)).opacity(0.6)
                    if abs(deck.pitchPct) >= 0.1 {
                        Text(String(format: "%+.1f%%", deck.pitchPct)).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(color)
                    }
                }
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(deck.track == nil ? " " : "-" + clock(max(0, deck.dur - livePos(deck)))).font(.caption.monospacedDigit()).opacity(0.7)
                }
                if deck.track != nil && !deck.sure { Text("Beats unsure: cuts only").font(.system(size: 9, weight: .semibold)).opacity(0.55) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if number == 1 { meters(color) }
        }
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(deck.onAir ? color.opacity(0.7) : .clear, lineWidth: 1.5))
    }

    private func meters(_ color: Color) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                VStack(spacing: 2) {
                    GeometryReader { g in
                        VStack { Spacer(minLength: 0); RoundedRectangle(cornerRadius: 2).fill(i == 0 ? color : .white.opacity(0.85)).frame(height: g.size.height * CGFloat(deck.meters[i])) }
                    }
                    .frame(width: 6)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 2))
                    Text(["B", "M", "T"][i]).font(.system(size: 8, weight: .bold)).opacity(0.6)
                }
            }
        }
        .frame(height: 96)
        .animation(.linear(duration: 0.08), value: deck.meters)
        .accessibilityHidden(true)
    }
}

/// The cover as a spinning record.
struct Platter: View {
    let deck: DJLive.DeckView
    let color: Color
    var body: some View {
        TimelineView(.animation(paused: !deck.playing)) { _ in
            let angle = livePos(deck) * 0.5556 * 360          // 33⅓ turns a minute
            ZStack {
                Circle().fill(Color.black)
                Circle().stroke(.white.opacity(0.07), lineWidth: 10).padding(6)
                if let t = deck.track {
                    Cover(track: t, radius: 40).frame(width: 52, height: 52).clipShape(Circle())
                }
                Circle().fill(Color.black).frame(width: 6, height: 6)
                Capsule().fill(color).frame(width: 3, height: 12).offset(y: -38)
            }
            .frame(width: 88, height: 88)
            .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
        }
        .accessibilityHidden(true)
    }
}

/// The middle: beat lights, what happens next, the crossfader and Mix now.
struct MixerPanel: View {
    @Environment(PlayerModel.self) private var player
    let live: DJLive
    @State private var dragging: Double?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(i == live.beat ? beatColor : .white.opacity(0.15)).frame(width: 10, height: 10)
                }
                if let l = live.locked {
                    Text(l ? "SYNC" : "NUDGING").font(.system(size: 9, weight: .heavy)).foregroundStyle(l ? .green : .orange)
                }
            }
            Text(live.countdown ?? (live.mixing ? "Mixing" : "Up next ready"))
                .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Menu {
                Button { player.dj.setNext(nil) } label: { Label("Auto (the app picks)", systemImage: "wand.and.stars") }
                Divider()
                ForEach(DJChange.allCases) { c in
                    Button { player.dj.setNext(c) } label: { Label(c.name, systemImage: c.symbol) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Next:").opacity(0.6)
                    Text(player.dj.chosenNext?.name ?? live.next ?? "Auto").fontWeight(.bold)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5).background(.white.opacity(0.12), in: Capsule())
            }
            crossfader
            Button { tap(.medium); player.dj.mixNow() } label: {
                Label("Mix now", systemImage: "arrow.left.arrow.right").font(.subheadline.weight(.heavy))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(live.canMix ? Theme.accent : Color.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(live.canMix ? Color.black : Color.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!live.canMix)
        }
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var beatColor: Color { live.locked == false ? .orange : live.locked == true ? .green : .white }

    private var crossfader: some View {
        GeometryReader { g in
            let x = dragging ?? live.fader
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [deckColors[0].opacity(0.5), deckColors[1].opacity(0.5)], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 4).fill(.white)
                    .frame(width: 22, height: 30)
                    .shadow(radius: 3)
                    .offset(x: CGFloat(x) * (w - 22))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let nx = max(0, min(1, Double((v.location.x - 11) / (w - 22))))
                    dragging = nx
                    player.dj.faderDrag(nx)
                }
                .onEnded { _ in
                    dragging = nil
                    player.dj.faderRelease()
                })
        }
        .frame(height: 34)
        .overlay(alignment: .bottom) {
            HStack { Text("1"); Spacer(); Text("CROSSFADER").opacity(0.5); Spacer(); Text("2") }
                .font(.system(size: 8, weight: .heavy)).offset(y: 10)
        }
        .padding(.bottom, 8)
        .accessibilityElement()
        .accessibilityLabel("Crossfader")
        .accessibilityValue(live.fader < 0.5 ? "Deck 1" : "Deck 2")
    }
}

/// Live effects and loops for the playing song.
struct PadRow: View {
    @Environment(PlayerModel.self) private var player
    let live: DJLive
    var body: some View {
        let dj = player.dj
        HStack(spacing: 6) {
            pad("Echo", "dot.radiowaves.right", on: live.echo, enabled: !live.mixing) { dj.toggleEcho() }
            pad("Filter", "line.3.horizontal.decrease", on: live.filter, enabled: !live.mixing) { dj.toggleFilter() }
            pad("Reverb", "cloud.fill", on: live.reverb, enabled: !live.mixing) { dj.toggleReverb() }
            pad("Roll", "repeat", on: live.rolling, enabled: !live.mixing && live.loopBeats == nil) { dj.rollNow() }
            pad("Brake", "tortoise.fill", on: false, enabled: live.canMix) { dj.mixNow(.brake) }
            pad("Backspin", "gobackward", on: false, enabled: live.canMix) { dj.mixNow(.backspin) }
            Divider().frame(height: 30).overlay(.white.opacity(0.2))
            pad("Loop 4", "repeat.1", on: live.loopBeats == 4, enabled: !live.mixing && (live.loopBeats == nil || live.loopBeats == 4)) { dj.toggleLoop(4) }
            pad("Loop 8", "repeat", on: live.loopBeats == 8, enabled: !live.mixing && (live.loopBeats == nil || live.loopBeats == 8)) { dj.toggleLoop(8) }
            pad("Chorus", "music.note", on: false, enabled: !live.mixing && live.loopBeats == nil) { dj.jumpToHook() }
        }
    }

    private func pad(_ title: String, _ icon: String, on: Bool, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button { tap(.medium); action() } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.subheadline.weight(.bold))
                Text(title).font(.system(size: 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(on ? Theme.accent.opacity(0.9) : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(on ? Color.black : Color.white)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
