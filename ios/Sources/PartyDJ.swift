import Foundation
import AVFoundation

/// Party mode's own player: two decks, like a DJ controller. While one song plays, the next is downloaded and
/// analysed (hook, tempo, beats, loudness), and the change-over is mixed: the incoming song is sped up or slowed
/// to the same tempo, its beats are lined up and kept locked (small nudges, like a DJ's jog wheel), the basses swap
/// on the downbeat of its hook, and some change-overs filter or echo the old song out. Songs whose tempos can't
/// meet (or whose beats can't be trusted) get a clean DJ cut with an echo instead of a blend.
/// Normal listening never touches this; it is only used while Party mode is on.
@MainActor
final class PartyDJ {
    struct Prepared {
        let track: Track
        let url: URL
        let file: AVAudioFile
        let duration: Double
        let hook: Double            // where the song starts (snapped to a beat when the beats are known)
        let hookSource: String
        let grid: BeatGrid?
        let gainDB: Float
        let temporary: Bool         // a downloaded copy that can be deleted once the song has been played
    }

    enum Style: String { case blend, filter, echo, cut }

    @MainActor final class Deck {
        let node = AVAudioPlayerNode()
        let input = AVAudioMixerNode()          // volume, and turns any sample rate into the engine's
        let pitch = AVAudioUnitTimePitch()      // tempo without changing the key
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        let delay = AVAudioUnitDelay()
        var song: Prepared?
        var segStart: Double = 0                // the song position the scheduled part starts at
        var generation = 0
        var lastPos: Double = 0
        var rate: Float = 1
        var connectedRate: Double = 0
    }

    struct Mix {
        let style: Style
        let startA: Double          // the outgoing song's position when the incoming one starts
        let swapA: Double           // ... and when the basses swap (the incoming song's hook)
        let bStart: Double          // where the incoming song starts
        let bPeriod: Double         // a beat of the incoming song, in its own seconds
        let rateB: Float            // the incoming song's tempo during the mix
        let beats: Double           // beats from the start of the incoming song to its hook
        var begun = false
    }

    weak var host: PlayerModel?
    var fetch: ((Track) async throws -> (url: URL, temporary: Bool))?
    private let engine = AVAudioEngine()
    private let bus = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private var a = Deck(), b = Deck()
    private var timer: Timer?
    private var plan: Mix?
    private var mixStartedAt: Double?         // B's own position when the mix began, once it is running
    private var prepared: [String: Prepared] = [:]
    private var preparing: [String: Task<Void, Never>] = [:]
    private var failed = Set<String>()
    private var mixCount = 0
    private var glideFrom: Float?             // after a mix, the new song eases back to its own tempo
    private var glideStartPos = 0.0
    private(set) var playing = false
    private var waitingFor: String?           // a song that should start as soon as it is ready
    private var built = false
    private var lastReport = -1.0

    init() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let resume = ((n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0) & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
            MainActor.assumeIsolated { self?.interrupted(began: type == .began, resume: resume) }
        }
    }

    // MARK: setting up

    private func build() {
        guard !built else { return }
        built = true
        let fmt0 = engine.mainMixerNode.outputFormat(forBus: 0)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: fmt0.sampleRate > 0 ? fmt0.sampleRate : 44100, channels: 2)
        engine.attach(bus); engine.attach(limiter)
        engine.connect(bus, to: limiter, format: stereo)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereo)
        for d in [a, b] {
            engine.attach(d.node); engine.attach(d.input); engine.attach(d.pitch); engine.attach(d.eq); engine.attach(d.delay)
            let low = d.eq.bands[0]
            low.filterType = .lowShelf; low.frequency = 180; low.gain = 0; low.bypass = false
            let hp = d.eq.bands[1]
            hp.filterType = .highPass; hp.frequency = 20; hp.bypass = true
            d.delay.wetDryMix = 0; d.delay.feedback = 0; d.delay.lowPassCutoff = 9000
            engine.connect(d.input, to: d.pitch, format: stereo)
            engine.connect(d.pitch, to: d.eq, format: stereo)
            engine.connect(d.eq, to: d.delay, format: stereo)
            engine.connect(d.delay, to: bus, format: stereo)
        }
        engine.prepare()
    }

    private func ensureRunning() {
        build()
        if !engine.isRunning {
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
        }
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 40, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func reset(_ d: Deck) {
        d.generation += 1
        d.node.stop()
        d.input.outputVolume = 1
        d.pitch.rate = 1; d.rate = 1
        d.eq.bands[0].gain = 0
        d.eq.bands[1].bypass = true; d.eq.bands[1].frequency = 20
        d.delay.wetDryMix = 0; d.delay.feedback = 0
        d.node.volume = 1
        if let s = d.song, s.temporary { try? FileManager.default.removeItem(at: s.url) }
        d.song = nil
    }

    // MARK: what the player model calls

    /// Starts this song now (at its hook), dropping anything that was playing.
    func play(_ t: Track) {
        ensureRunning()
        plan = nil; mixStartedAt = nil; glideFrom = nil
        reset(a); reset(b)
        playing = true
        if let p = prepared[t.id] {
            startCold(p)
        } else {
            waitingFor = t.id
            host?.djStatus("Getting the song ready…")
            prepare(t, first: true)
        }
        prepareAhead()
    }

    /// Skip: mix into the next song on the next beat when it is ready (an echo and a cut, like a DJ would), else load it.
    func skip() {
        guard let host, host.queue.indices.contains(host.index + 1) else { host?.djEnded(); return }
        if mixStartedAt != nil { finishMix(); return }
        let n = host.queue[host.index + 1]
        if let p = prepared[n.id], let s = a.song, playing, mixStartedAt == nil {
            let pos = position(a)
            let at = s.grid.map { g in g.snap(pos + g.period * 0.6) } ?? pos + 0.3
            plan = Mix(style: .cut, startA: at, swapA: at, bStart: p.hook, bPeriod: p.grid?.period ?? 0.5, rateB: 1, beats: 0)
            host.djStatus("Skipping on the beat…")
        } else {
            host.djAdvance(to: host.index + 1, mixed: false)
            play(n)
        }
    }

    func toggle() {
        guard a.song != nil else { if let h = host { play(h.current) }; return }
        if playing { engine.pause(); playing = false } else { ensureRunning(); playing = true }
        host?.djPlaying(playing)
    }

    func seek(_ seconds: Double) {
        guard let s = a.song else { return }
        if mixStartedAt != nil { finishMix() }
        plan = nil
        schedule(a, s, from: max(0, min(seconds, s.duration - 1)), at: nil)
        if playing { a.node.play() }
        replan()
    }

    /// The clip length or "keep playing" changed: work out where the next change-over goes again.
    func replan() {
        if mixStartedAt == nil { plan = nil }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        plan = nil; mixStartedAt = nil; waitingFor = nil
        reset(a); reset(b)
        engine.stop()
        playing = false
        for (_, t) in preparing { t.cancel() }
        preparing = [:]
        for (_, p) in prepared where p.temporary { try? FileManager.default.removeItem(at: p.url) }
        prepared = [:]
        failed = []
    }

    /// Where the current song is, in seconds.
    var currentPosition: Double { position(a) }
    var nextReady: Bool {
        guard let h = host, h.queue.indices.contains(h.index + 1) else { return false }
        return prepared[h.queue[h.index + 1].id] != nil
    }
    var currentBPM: Double? { a.song?.grid.map { $0.bpm * Double(a.rate) } }

    // MARK: getting songs ready

    private func prepareAhead() {
        guard let h = host else { return }
        for i in (h.index + 1)..<min(h.queue.count, h.index + 4) { prepare(h.queue[i], first: false) }
    }

    private func prepare(_ t: Track, first: Bool) {
        guard prepared[t.id] == nil, preparing[t.id] == nil, !failed.contains(t.id) || first, let fetch else { return }
        let engineHost = EngineHost.shared
        preparing[t.id] = Task { [weak self] in
            defer { self?.preparing[t.id] = nil }
            do {
                let got = try await fetch(t)
                let path = "/api/hook/\(t.id)?title=\(EngineHost.enc(t.title))&artist=\(EngineHost.enc(t.artist))&dur=\(t.seconds)"
                let hook = (try? await engineHost.get(path, as: HookInfo.self)) ?? HookInfo(start: 0, source: "none")
                let url = got.url
                let analysis = await Task.detached(priority: .utility) { BeatTracker.analyzeFile(url, hook: hook.start) }.value
                guard let self, !Task.isCancelled, let file = try? AVAudioFile(forReading: url) else { return }
                let dur = analysis?.duration ?? Double(file.length) / file.processingFormat.sampleRate
                var start = hook.start > 3 && hook.start < dur - 25 ? hook.start : 0
                if start > 0, let g = analysis?.grid { start = g.snap(start) }
                let p = Prepared(track: t, url: url, file: file, duration: dur, hook: max(0, start), hookSource: start > 0 ? hook.source : "none",
                                 grid: analysis?.grid, gainDB: analysis?.gainDB ?? 0, temporary: got.temporary)
                self.prepared[t.id] = p
                if self.waitingFor == t.id { self.waitingFor = nil; self.startCold(p) }
                self.prepareAhead()
            } catch {
                guard let self else { return }
                self.failed.insert(t.id)
                if self.waitingFor == t.id {
                    self.waitingFor = nil
                    self.host?.djStatus("Couldn't load \(t.title). Skipping it.")
                    self.skipBroken()
                }
            }
        }
    }

    /// The song that should start could not be loaded: on to the one after it.
    private func skipBroken() {
        guard let h = host, h.queue.indices.contains(h.index + 1) else { host?.djEnded(); return }
        h.djAdvance(to: h.index + 1, mixed: false)
        play(h.current)
    }

    // MARK: playing

    private func schedule(_ d: Deck, _ s: Prepared, from: Double, at time: AVAudioTime?) {
        d.generation += 1
        d.node.stop()
        let fmt = s.file.processingFormat
        if d.connectedRate != fmt.sampleRate || d.node.outputFormat(forBus: 0).channelCount != fmt.channelCount {
            engine.disconnectNodeOutput(d.node)
            engine.connect(d.node, to: d.input, format: fmt)
            d.connectedRate = fmt.sampleRate
        }
        d.song = s
        d.eq.globalGain = s.gainDB
        let sr = fmt.sampleRate
        let startFrame = AVAudioFramePosition(max(0, from) * sr)
        let count = AVAudioFrameCount(max(0, s.file.length - startFrame))
        d.segStart = Double(startFrame) / sr
        d.lastPos = d.segStart
        guard count > 0 else { return }
        let gen = d.generation
        d.node.scheduleSegment(s.file, startingFrame: startFrame, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self, weak d] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if let self, let d, d.generation == gen { self.deckFinished(d) } } }
        }
        d.node.play(at: time)
    }

    /// The first song, or one after a skip without a mix: straight in at the hook with a quick fade.
    private func startCold(_ p: Prepared) {
        ensureRunning()
        prepared[p.track.id] = nil
        reset(b)
        a.input.outputVolume = 0
        schedule(a, p, from: p.hook, at: nil)
        if !playing { engine.pause() }
        fade(a, to: 1, over: 0.6)
        host?.djStarted(p, mixed: false)
        prepareAhead()
    }

    private var fades: [ObjectIdentifier: (deck: Deck, from: Float, to: Float, start: Date, length: Double)] = [:]
    private func fade(_ d: Deck, to v: Float, over s: Double) {
        fades[ObjectIdentifier(d)] = (d, d.input.outputVolume, v, Date(), s)
    }

    private func position(_ d: Deck) -> Double {
        if let rt = d.node.lastRenderTime, let pt = d.node.playerTime(forNodeTime: rt), pt.sampleRate > 0 {
            let p = d.segStart + Double(pt.sampleTime) / pt.sampleRate
            if p >= d.segStart - 0.001 { d.lastPos = p }
        }
        return d.lastPos
    }

    private func deckFinished(_ d: Deck) {
        if d === a {
            if mixStartedAt != nil { finishMix(); return }
            // the song ran out without a mix (the next one wasn't ready): carry on with the next one
            guard let h = host, h.queue.indices.contains(h.index + 1) else { host?.djEnded(); return }
            h.djAdvance(to: h.index + 1, mixed: false)
            play(h.current)
        }
    }

    // MARK: planning the change-over

    private var clip: Double { host?.party?.keep == true ? 0 : (host?.party?.clip ?? 0) }

    private func makePlan() -> Mix? {
        guard let h = host, let s = a.song, h.queue.indices.contains(h.index + 1) else { return nil }
        pickClosestTempo()
        guard let n = prepared[h.queue[h.index + 1].id] else { return nil }
        let pos = position(a)
        let end = s.duration - 3
        let gA = s.grid, gB = n.grid
        // tempo: the same, or half/double time, within 8%
        var factor = 1.0, ratio = 0.0
        if let gA, let gB, gA.sure, gB.sure {
            let tempoA = gA.bpm * Double(a.rate)
            for f in [1.0, 2.0, 0.5] {
                let r = tempoA / (gB.bpm * f)
                if ratio == 0 || abs(log(r)) < abs(log(ratio)) { ratio = r; factor = f }
            }
        }
        let matched = ratio > 0 && abs(ratio - 1) <= 0.08
        if matched, let gA, let gB {
            let perA = gA.period, perB = gB.period / factor
            let phrase = 16.0 * perA
            // the change-over lands on a phrase boundary counted from the hook (choruses come in 8 and 16 bars)
            var swap: Double
            if clip > 0 {
                swap = s.hook + max(1, (clip / phrase).rounded()) * phrase
            } else {
                swap = s.hook + ((end - s.hook) / phrase).rounded(.down) * phrase
                if swap < s.hook + phrase { swap = gA.snap(end - 4 * perA) }
            }
            swap = min(swap, gA.snap(end - 2 * perA))
            var beats = 16.0
            while beats > 4 && n.hook - beats * perB < 0 { beats /= 2 }
            let startA = swap - beats * perA
            if n.hook - beats * perB >= 0, startA > pos + 1 {
                let styles: [Style] = [.blend, .filter, .blend, .echo]
                let style = beats >= 8 ? styles[mixCount % styles.count] : .blend
                return Mix(style: style, startA: startA, swapA: swap, bStart: n.hook - beats * perB, bPeriod: perB, rateB: Float(ratio), beats: beats)
            }
        }
        // no blend: an echo and a clean cut into the next hook, on a beat when the beats are known
        var at = clip > 0 ? s.hook + clip : end - 1
        if let gA { at = gA.snap(at) }
        at = max(min(at, end - 1), pos + 0.5)
        return Mix(style: .cut, startA: at, swapA: at, bStart: n.hook, bPeriod: n.grid?.period ?? 0.5, rateB: 1, beats: 0)
    }

    /// Of the next few songs that are ready, the one whose tempo is closest to this one plays next (only when the
    /// song lined up next could not be blended and another one could).
    private func pickClosestTempo() {
        guard let h = host, let g = a.song?.grid, g.sure else { return }
        let tempo = g.bpm * Double(a.rate)
        func distance(_ t: Track) -> Double? {
            guard let p = prepared[t.id], let gb = p.grid, gb.sure else { return nil }
            return [1.0, 2.0, 0.5].map { abs(log(tempo / (gb.bpm * $0))) }.min()
        }
        let next = h.index + 1
        guard h.queue.indices.contains(next), (distance(h.queue[next]) ?? 1) > log(1.08) else { return }
        var best: Int?
        for i in (next + 1)..<min(h.queue.count, next + 3) {
            if let d = distance(h.queue[i]), d <= log(1.08), best == nil || d < distance(h.queue[best!])! { best = i }
        }
        if let best { h.djMoveUp(best, to: next) }
    }

    // MARK: every 25 ms

    private func step() {
        guard let h = host, h.party != nil else { return }
        applyFades()
        guard let s = a.song else { return }
        let pos = position(a)
        if playing && abs(pos - lastReport) >= 0.25 { lastReport = pos; h.djTime(pos, s.duration) }
        guard playing else { return }
        glide()
        if mixStartedAt == nil {
            if plan == nil, nextReadyForPlan { plan = makePlan() }
            if var p = plan, !p.begun, pos >= p.startA - 0.4 { p.begun = true; plan = p; begin(p, posA: pos) }
        } else if let p = plan {
            mixing(p)
        }
    }

    private var nextReadyForPlan: Bool {
        guard let h = host, h.queue.indices.contains(h.index + 1) else { return false }
        if prepared[h.queue[h.index + 1].id] != nil { return true }
        // not ready this close to the end: the song plays on and the next one loads when it ends
        return false
    }

    private func begin(_ p: Mix, posA: Double) {
        guard let h = host, h.queue.indices.contains(h.index + 1), let n = prepared[h.queue[h.index + 1].id] else { plan = nil; return }
        // the moment the outgoing song reaches startA, in the engine's clock
        let wait = max(0.05, (p.startA - posA) / Double(a.rate))
        var at: AVAudioTime?
        if let rt = engine.outputNode.lastRenderTime, rt.isHostTimeValid {
            at = AVAudioTime(hostTime: rt.hostTime + AVAudioTime.hostTime(forSeconds: wait))
        }
        b.input.outputVolume = 0
        b.node.volume = 1
        b.delay.wetDryMix = 0; b.delay.feedback = 0
        b.eq.bands[1].bypass = true; b.eq.bands[1].frequency = 20
        b.pitch.rate = p.rateB; b.rate = p.rateB
        b.eq.bands[0].gain = p.style == .cut ? 0 : -26
        prepared[n.track.id] = nil
        schedule(b, n, from: p.bStart, at: at)
        mixStartedAt = p.bStart
        mixCount += 1
        glideFrom = nil
        if p.style != .cut { h.djStatus(p.style == .filter ? "Mixing · filter" : p.style == .echo ? "Mixing · echo" : "Mixing · beat-matched") }
    }

    private func mixing(_ p: Mix) {
        let posB = position(b)
        let posA = position(a)
        guard posB > p.bStart + 0.005 || posA >= p.startA else { return }      // B hasn't started yet
        let beat = (posB - p.bStart) / p.bPeriod                                  // beats of the incoming song so far
        let ease: (Double) -> Float = { x in let c = max(0, min(1, x)); return Float(c * c * (3 - 2 * c)) }
        if p.style == .cut {
            // the old song echoes away on the beat while the new one comes straight in at its hook
            if a.delay.wetDryMix == 0, let g = a.song?.grid {
                a.delay.delayTime = min(2, g.period * 0.75 / Double(a.rate))
                a.delay.feedback = 45
                a.delay.wetDryMix = 45
                a.node.volume = 0
            } else if a.song?.grid == nil, a.delay.wetDryMix == 0 {
                a.delay.delayTime = 0.375; a.delay.feedback = 40; a.delay.wetDryMix = 40; a.node.volume = 0
            }
            b.input.outputVolume = ease(beat / 0.75)
            if posB - p.bStart > 4 { finishMix() }
            return
        }
        lockBeats(p, posA: posA, posB: posB)
        // the incoming song fades in without its bass over the first half
        b.input.outputVolume = ease(beat / (p.beats / 2))
        if p.style == .filter {
            let x = max(0, min(1, (beat - p.beats / 2) / (p.beats / 2)))
            a.eq.bands[1].bypass = x <= 0
            a.eq.bands[1].frequency = Float(20 * pow(60.0, x))                   // 20 Hz → 1.2 kHz
        }
        if beat >= p.beats {
            // the hook arrives: the basses swap on the downbeat
            b.eq.bands[0].gain = 0
            a.eq.bands[0].gain = -26
            if p.style == .echo {
                if a.delay.wetDryMix == 0, let g = a.song?.grid {
                    a.delay.delayTime = min(2, g.period * 0.75 / Double(a.rate)); a.delay.feedback = 50; a.delay.wetDryMix = 50
                    a.node.volume = 0
                }
                if beat >= p.beats + 8 { finishMix() }
            } else {
                a.input.outputVolume = 1 - ease((beat - p.beats) / 4)
                if beat >= p.beats + 4 { finishMix() }
            }
        } else if beat >= p.beats - 0.5 {
            b.eq.bands[0].gain = 0                                                // a touch early, so the kick is there on the 1
        }
    }

    /// Keeps the two songs' beats together: if the incoming one drifts ahead or behind, it is nudged (at most 3%).
    private func lockBeats(_ p: Mix, posA: Double, posB: Double) {
        guard let gA = a.song?.grid else { return }
        let phA = gA.phase(posA)
        let x = (posB - p.bStart) / p.bPeriod
        let phB = x - x.rounded(.down)
        var e = phB - phA
        if e > 0.5 { e -= 1 }
        if e < -0.5 { e += 1 }
        let wallBeat = gA.period / Double(a.rate)
        let nudge = max(-0.03, min(0.03, -e * wallBeat / 0.8))
        let r = p.rateB * Float(1 + nudge)
        if abs(r - b.pitch.rate) > 0.0005 { b.pitch.rate = r }
        b.rate = p.rateB
    }

    private func finishMix() {
        guard let h = host, let n = b.song else { mixStartedAt = nil; plan = nil; return }
        let style = plan?.style
        let rateB = b.pitch.rate
        mixStartedAt = nil
        plan = nil
        // the old deck rings out its echo, then is cleared
        let old = a
        old.generation += 1
        if style == .cut || style == .echo {
            let gen = old.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, old.generation == gen, old !== self.a else { return }
                self.reset(old)
                old.node.volume = 1
            }
            old.node.stop()
        } else {
            reset(old)
        }
        a = b
        b = old
        a.input.outputVolume = 1
        a.eq.bands[0].gain = 0
        if abs(rateB - 1) > 0.002 { glideFrom = rateB; glideStartPos = position(a) } else { a.pitch.rate = 1; a.rate = 1 }
        let next = h.index + 1
        h.djAdvance(to: next, mixed: true)
        h.djStarted(n, mixed: style != .cut)
        prepareAhead()
    }

    /// After a mix the new song slides back to its own tempo over 16 of its beats.
    private func glide() {
        guard let from = glideFrom, let g = a.song?.grid else { return }
        let x = min(1, (position(a) - glideStartPos) / (16 * g.period))
        let r = from + (1 - from) * Float(x)
        a.pitch.rate = r; a.rate = r
        if x >= 1 { glideFrom = nil; a.pitch.rate = 1; a.rate = 1 }
    }

    private func applyFades() {
        for (k, f) in fades {
            let x = min(1, Date().timeIntervalSince(f.start) / f.length)
            f.deck.input.outputVolume = f.from + (f.to - f.from) * Float(x)
            if x >= 1 { fades[k] = nil }
        }
    }

    // MARK: interruptions

    private func configurationChanged() {
        // headphones plugged or unplugged: the engine stopped; carry on from the same place
        guard a.song != nil else { return }
        if mixStartedAt != nil { finishMix() }
        plan = nil
        guard let cur = a.song else { return }
        let pos = position(a)
        try? engine.start()
        schedule(a, cur, from: pos, at: nil)
        if !playing { engine.pause() }
    }

    private func interrupted(began: Bool, resume: Bool) {
        guard a.song != nil else { return }
        if began {
            playing = false
            host?.djPlaying(false)
        } else if resume {
            ensureRunning()
            playing = true
            host?.djPlaying(true)
        }
    }
}
