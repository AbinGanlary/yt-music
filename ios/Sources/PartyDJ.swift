import Foundation
import AVFoundation
import os
import QuartzCore

/// The ways one song can change into the next, like a DJ would do it.
enum DJChange: String, CaseIterable, Identifiable {
    case longBlend, bassSwap, filterIn, filterOut, echoOut, reverbWash, loopRoll, brake, backspin, dropCut
    var id: String { rawValue }
    var name: String {
        switch self {
        case .longBlend: "Long blend"
        case .bassSwap: "Bass swap"
        case .filterIn: "Filter in"
        case .filterOut: "Filter out"
        case .echoOut: "Echo out"
        case .reverbWash: "Reverb wash"
        case .loopRoll: "Loop roll"
        case .brake: "Brake"
        case .backspin: "Backspin"
        case .dropCut: "Drop cut"
        }
    }
    var symbol: String {
        switch self {
        case .longBlend: "water.waves"
        case .bassSwap: "arrow.left.arrow.right"
        case .filterIn: "line.3.horizontal.decrease"
        case .filterOut: "line.3.horizontal.decrease.circle"
        case .echoOut: "dot.radiowaves.right"
        case .reverbWash: "cloud.fill"
        case .loopRoll: "repeat"
        case .brake: "tortoise.fill"
        case .backspin: "gobackward"
        case .dropCut: "scissors"
        }
    }
    /// Both songs play together, so their tempos must meet.
    var blends: Bool { [.longBlend, .bassSwap, .filterIn, .filterOut].contains(self) }
    /// Needs the outgoing song's beats.
    var needsBeats: Bool { blends || [.loopRoll, .brake, .backspin].contains(self) }
    /// Beats of effect on the old song before the new one drops in (for the changes that don't blend).
    var fxBeats: Double {
        switch self {
        case .reverbWash, .loopRoll: 4
        case .brake: 2
        case .backspin: 1
        default: 0
        }
    }
}

/// Live numbers for the DJ view, updated 20 times a second. Only the DJ view watches this.
@MainActor
@Observable
final class DJLive {
    struct DeckView {
        var track: Track?
        var bpm: Double?
        var pitchPct: Double = 0
        var pos: Double = 0
        var at: Double = 0              // when `pos` was measured (CACurrentMediaTime)
        var rate: Double = 1
        var playing = false
        var dur: Double = 1
        var hook: Double = 0
        var mixAt: Double?              // where the next change starts (on the playing deck)
        var anchor: Double?
        var period: Double?
        var sure = false
        var meters: [Float] = [0, 0, 0]
        var onAir = false               // the song the party is on
        var wave: Wave?
    }
    var decks = [DeckView(), DeckView()]
    var fader = 0.0                     // 0 = deck 1, 1 = deck 2
    var countdown: String?
    var next: String?
    var locked: Bool?                   // during a blend: are the beats together?
    var beat = 0
    var loopBeats: Int?
    var echo = false, filter = false, reverb = false, rolling = false
    var mixing = false
    var canMix = false
}

/// Bass, mid and treble levels of a deck, written by the audio thread and read by the main thread.
final class MeterBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: 3))
    func set(_ v: [Float]) { lock.withLock { $0 = v } }
    var value: [Float] { lock.withLock { $0 } }
}

/// Party mode's own player: two decks, like a DJ controller. While one song plays, the next ones are downloaded and
/// analysed (hook, tempo, beats, loudness, shape), and every change-over is mixed in one of ten DJ ways: blends where
/// the incoming song is tempo-matched and beat-locked (small nudges, like a DJ's jog wheel) with the basses swapped on its
/// hook, or effects on the outgoing song (echo, reverb, loop roll, brake, backspin, a clean cut) when the tempos can't meet.
/// Normal listening never touches this; it is only used while Party mode is on.
@MainActor
final class PartyDJ {
    struct Prepared {
        let track: Track
        let url: URL
        let file: AVAudioFile
        let duration: Double
        let hook: Double            // where the song comes in (snapped to a beat when the beats are known)
        let hookSource: String
        let grid: BeatGrid?
        let gainDB: Float
        let wave: Wave?
        let temporary: Bool         // a downloaded copy that can be deleted once the song has been played
    }

    /// A loop (Loop 4 / Loop 8): the deck's second player repeats the beats; the song carries on after it is let go.
    struct LoopMap {
        let start: Double
        let frames: AVAudioFramePosition
        let beats: Int
        let buffer: AVAudioPCMBuffer
        let player: Int
        let startSec: Double
        var scheduled = 2
        var contBase: AVAudioFramePosition?
        var contStart = 0.0
        var switched = false
    }

    @MainActor final class Deck {
        let number: Int
        let players = [AVAudioPlayerNode(), AVAudioPlayerNode()]
        var main = 0
        var node: AVAudioPlayerNode { players[main] }
        var fx: AVAudioPlayerNode { players[1 - main] }
        let input = AVAudioMixerNode()          // volume, and turns any sample rate into the engine's
        let pitch = AVAudioUnitTimePitch()      // tempo without changing the key (and the brake's pitch drop)
        let eq = AVAudioUnitEQ(numberOfBands: 5) // bass, mid, treble, high-pass, low-pass
        let delay = AVAudioUnitDelay()
        let reverb = AVAudioUnitReverb()
        let meter = MeterBox()
        var song: Prepared?
        var segStart: Double = 0
        var loop: LoopMap?
        var generation = 0
        var lastPos: Double = 0
        var rate: Float = 1
        var format: AVAudioFormat?
        init(_ n: Int) { number = n }
    }

    struct Mix {
        let change: DJChange
        let startA: Double          // the outgoing song's position when the change starts
        let dropA: Double           // ... and when the incoming song's hook lands
        let bStart: Double          // where the incoming song starts
        let bPeriod: Double         // a beat of the incoming song, in its own seconds
        let rateB: Float            // the incoming song's tempo during the mix
        let beats: Double           // blends: beats from the start of the incoming song to its hook
        let total: Double           // blends: beats until the mix is over
        let matched: Bool
        let incoming: Prepared
        var startSec = 0.0          // engine clock
        var dropSec = 0.0
    }

    weak var host: PlayerModel?
    var fetch: ((Track) async throws -> (url: URL, temporary: Bool))?
    let live = DJLive()
    private let engine = AVAudioEngine()
    private let bus = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private var a = Deck(1), b = Deck(2)
    private var timer: Timer?
    private var plan: Mix?
    private var running: Mix?
    private var prepared: [String: Prepared] = [:]
    private var preparing: [String: Task<Void, Never>] = [:]
    private var failed = Set<String>()
    private var mixCount = 0
    private var lastChange: DJChange?
    private var forced: DJChange?
    private var glideFrom: Float?
    private var glideStartPos = 0.0
    private(set) var playing = false
    private var waitingFor: String?
    private var built = false
    private var lastReport = -1.0
    private var ticks = 0
    private var manual: Double?               // the crossfader held by the user (0 = outgoing, 1 = incoming)
    private var autoFrom: (x: Double, at: Double)?
    private var roll: (start: Double, end: Double)?
    private var filterOn = false

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
            for p in d.players { engine.attach(p) }
            engine.attach(d.input); engine.attach(d.pitch); engine.attach(d.eq); engine.attach(d.delay); engine.attach(d.reverb)
            let bands = d.eq.bands
            bands[0].filterType = .lowShelf; bands[0].frequency = 180
            bands[1].filterType = .parametric; bands[1].frequency = 1000; bands[1].bandwidth = 1.5
            bands[2].filterType = .highShelf; bands[2].frequency = 5000
            bands[3].filterType = .highPass; bands[3].frequency = 20
            bands[4].filterType = .lowPass; bands[4].frequency = 20000
            for (i, band) in bands.enumerated() { band.gain = 0; band.bypass = i >= 3 }
            d.delay.wetDryMix = 0; d.delay.feedback = 0; d.delay.lowPassCutoff = 9000
            d.reverb.loadFactoryPreset(.largeHall2); d.reverb.wetDryMix = 0
            engine.connect(d.input, to: d.pitch, format: stereo)
            engine.connect(d.pitch, to: d.eq, format: stereo)
            engine.connect(d.eq, to: d.delay, format: stereo)
            engine.connect(d.delay, to: d.reverb, format: stereo)
            engine.connect(d.reverb, to: bus, format: stereo)
            d.reverb.installTap(onBus: 0, bufferSize: 2048, format: nil, block: Self.meterTap(d.meter))
        }
        engine.prepare()
    }

    /// Measures bass, mid and treble on the audio thread (made outside the main actor, so it may run there).
    nonisolated private static func meterTap(_ box: MeterBox) -> AVAudioNodeTapBlock {
        return { buf, _ in
            guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return }
            let n = Int(buf.frameLength)
            var lp: Float = 0, prev: Float = 0, lo: Float = 0, hi: Float = 0, all: Float = 0
            for i in 0..<n {
                let s = ch[0][i]
                lp += 0.028 * (s - lp)
                let h = s - prev
                prev = s
                lo += lp * lp; hi += h * h; all += s * s
            }
            func level(_ e: Float) -> Float { max(0, min(1, (20 * log10(max(1e-6, sqrt(e / Float(n)))) + 48) / 44)) }
            box.set([level(lo * 2), level(max(0, all - lo)), level(hi * 0.6)])
        }
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

    private func clearEffects(_ d: Deck) {
        d.input.outputVolume = 1
        for p in d.players { p.volume = 1 }
        d.pitch.rate = 1; d.pitch.pitch = 0; d.rate = 1
        for (i, band) in d.eq.bands.enumerated() { band.gain = 0; band.bypass = i >= 3 }
        d.eq.bands[3].frequency = 20; d.eq.bands[4].frequency = 20000
        d.delay.wetDryMix = 0; d.delay.feedback = 0
        d.reverb.wetDryMix = 0
    }

    private func reset(_ d: Deck, keepFile: Bool = false) {
        d.generation += 1
        for p in d.players { p.stop() }
        d.loop = nil
        clearEffects(d)
        if !keepFile, let s = d.song, s.temporary { try? FileManager.default.removeItem(at: s.url) }
        d.song = nil
    }

    /// The engine's clock, in seconds.
    private var now: Double {
        if let rt = engine.outputNode.lastRenderTime, rt.isHostTimeValid { return AVAudioTime.seconds(forHostTime: rt.hostTime) }
        return AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }
    private func hostTime(_ sec: Double) -> AVAudioTime { AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: sec)) }

    // MARK: what the player model calls

    /// Starts this song now (at its hook), dropping anything that was playing.
    func play(_ t: Track) {
        ensureRunning()
        plan = nil; running = nil; glideFrom = nil; manual = nil; autoFrom = nil; roll = nil; filterOn = false
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

    /// Skip: mix into the next song on the next beat when it is ready, else load it.
    func skip() {
        guard let host, host.queue.indices.contains(host.index + 1) else { host?.djEnded(); return }
        if running != nil { finishMix(); return }
        let n = host.queue[host.index + 1]
        if prepared[n.id] != nil, a.song != nil, playing, a.loop == nil {
            let style = UserDefaults.standard.string(forKey: "mixStyle") ?? "auto"
            forced = style == "hype" ? [.loopRoll, .backspin, .dropCut].randomElement() : .echoOut
            plan = makePlan(soon: true)
            if plan != nil { host.djStatus("Skipping on the beat…"); return }
            host.djAdvance(to: host.index + 1, mixed: false)
            play(n)
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
        guard a.song != nil else { return }
        if running != nil { finishMix() }
        guard let cur = a.song else { return }
        plan = nil
        schedule(a, cur, from: max(0, min(seconds, cur.duration - 1)), at: nil)
        replan()
    }

    /// The clip length, "keep playing", the mix style or the chosen next change changed: plan the next change again.
    func replan() {
        if running == nil { plan = nil }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        plan = nil; running = nil; waitingFor = nil; manual = nil; autoFrom = nil; roll = nil
        reset(a); reset(b)
        engine.stop()
        playing = false
        for (_, t) in preparing { t.cancel() }
        preparing = [:]
        for (_, p) in prepared where p.temporary { try? FileManager.default.removeItem(at: p.url) }
        prepared = [:]
        failed = []
    }

    var currentPosition: Double { position(a) }
    var nextReady: Bool {
        guard let h = host, h.queue.indices.contains(h.index + 1) else { return false }
        return prepared[h.queue[h.index + 1].id] != nil || running != nil
    }
    var currentBPM: Double? { a.song?.grid.map { $0.bpm * Double(a.rate) } }
    var chosenNext: DJChange? { forced }

    // MARK: DJ controls

    /// Start the change to the next song now (on the next beat), optionally a particular kind.
    func mixNow(_ change: DJChange? = nil) {
        guard running == nil, a.loop == nil, playing, nextReady else { return }
        if let change { forced = change }
        plan = makePlan(soon: true)
    }

    /// The kind of the next change (nil = let the app choose).
    func setNext(_ change: DJChange?) {
        forced = change
        replan()
    }

    func toggleEcho() {
        guard let g = a.song?.grid else { return }
        live.echo.toggle()
        if live.echo {
            a.delay.delayTime = min(2, g.period * 0.75 / Double(a.rate)); a.delay.feedback = 40; a.delay.wetDryMix = 32
        } else {
            a.delay.wetDryMix = 0; a.delay.feedback = 0
        }
    }

    func toggleFilter() {
        filterOn.toggle()
        live.filter = filterOn
        let band = a.eq.bands[3]
        let from = band.bypass ? 20 : band.frequency
        let to: Float = filterOn ? 700 : 20
        band.bypass = false
        ramp(0.6) { [weak self] x in
            band.frequency = from * pow(to / from, x)
            if x >= 1, self?.filterOn == false { band.bypass = true }
        }
    }

    func toggleReverb() {
        live.reverb.toggle()
        let r = a.reverb, from = r.wetDryMix, to: Float = live.reverb ? 35 : 0
        ramp(0.4) { x in r.wetDryMix = from + (to - from) * x }
    }

    /// A one-bar roll: the next beat repeats in halves, then quarters, and the song carries on where it would have been.
    func rollNow() {
        guard running == nil, a.loop == nil, roll == nil, let s = a.song, let g = s.grid, playing else { return }
        let pos = position(a)
        let start = nextBeat(g, after: pos + 0.25)
        let lengths: [Double] = [0.5, 0.5, 0.5, 0.5, 0.25, 0.25, 0.25, 0.25]
        guard scheduleRoll(a, s, from: start, lengths: lengths, period: g.period) else { return }
        let startSec = now + (start - pos) / Double(a.rate)
        a.fx.volume = 1
        a.fx.play(at: hostTime(startSec))
        roll = (startSec, startSec + lengths.reduce(0, +) * g.period / Double(a.rate))
        live.rolling = true
    }

    /// Loop 4 or 8 beats from the next beat; call again to let go (the song carries on after the loop).
    func toggleLoop(_ beats: Int) {
        if var l = a.loop {
            guard l.contBase == nil, let s = a.song else { return }
            // let go: after the iterations already queued, the song continues from the end of the loop
            let sr = s.file.processingFormat.sampleRate
            l.contBase = AVAudioFramePosition(l.scheduled) * l.frames
            l.contStart = l.start + Double(l.frames) / sr
            a.loop = l
            let p = a.players[l.player]
            let startFrame = AVAudioFramePosition(l.contStart * sr)
            let count = AVAudioFrameCount(max(0, s.file.length - startFrame))
            let gen = a.generation
            let d = a
            if count > 0 {
                p.scheduleSegment(s.file, startingFrame: startFrame, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { if let self, d.generation == gen, d.node === p { self.deckFinished(d) } } }
                }
            }
            live.loopBeats = nil
            replan()
            return
        }
        guard running == nil, roll == nil, let s = a.song, let g = s.grid, playing else { return }
        let pos = position(a)
        let start = nextBeat(g, after: pos + 0.25)
        let sr = s.file.processingFormat.sampleRate
        let frames = AVAudioFramePosition(Double(beats) * g.period * sr)
        guard let buf = readAudio(s, from: start, frames: frames) else { return }
        let p = a.fx
        p.stop()
        p.volume = 1
        let idx = 1 - a.main
        let gen = a.generation
        let d = a
        for _ in 0..<2 { queueLoop(d, p, buf, gen) }
        let startSec = now + (start - pos) / Double(a.rate)
        p.play(at: hostTime(startSec))
        a.loop = LoopMap(start: start, frames: frames, beats: beats, buffer: buf, player: idx, startSec: startSec)
        plan = nil
        live.loopBeats = beats
    }

    private func queueLoop(_ d: Deck, _ p: AVAudioPlayerNode, _ buf: AVAudioPCMBuffer, _ gen: Int) {
        p.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataConsumed) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, d.generation == gen, var l = d.loop, l.contBase == nil, d.players[l.player] === p else { return }
                    l.scheduled += 1
                    d.loop = l
                    self.queueLoop(d, p, buf, gen)
                }
            }
        }
    }

    /// Back to the hook (the chorus) of the current song.
    func jumpToHook() {
        guard let s = a.song else { return }
        seek(s.hook)
    }

    /// The user moves the crossfader (0 = deck 1, 1 = deck 2).
    func faderDrag(_ physical: Double) {
        let x = a.number == 1 ? physical : 1 - physical
        autoFrom = nil
        if running == nil {
            guard x > 0.04, plan == nil || !(plan!.startA - position(a) < 0.6), a.loop == nil, playing, nextReady else { return }
            forced = .bassSwap
            plan = makePlan(soon: true, manual: true)
            guard plan != nil else { return }
        }
        manual = max(0, min(1, x))
    }

    func faderRelease() {
        guard let x = manual else { return }
        if running == nil && plan != nil { manual = nil; return }       // let go before the incoming song started: the mix runs itself
        if x <= 0.03 { cancelMix(); return }
        if x >= 0.97 { finishMix(); return }
        autoFrom = (x, now)
    }

    // MARK: getting songs ready

    private func prepareAhead() {
        guard let h = host, h.index + 1 < h.queue.count else { return }
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
                                 grid: analysis?.grid, gainDB: analysis?.gainDB ?? 0, wave: analysis?.wave, temporary: got.temporary)
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

    private func skipBroken() {
        guard let h = host, h.queue.indices.contains(h.index + 1) else { host?.djEnded(); return }
        h.djAdvance(to: h.index + 1, mixed: false)
        play(h.current)
    }

    // MARK: playing

    private func connect(_ d: Deck, _ fmt: AVAudioFormat) {
        if let f = d.format, f.sampleRate == fmt.sampleRate, f.channelCount == fmt.channelCount { return }
        for p in d.players {
            engine.disconnectNodeOutput(p)
            engine.connect(p, to: d.input, format: fmt)
        }
        d.format = fmt
    }

    private func schedule(_ d: Deck, _ s: Prepared, from: Double, at time: AVAudioTime?) {
        d.generation += 1
        for p in d.players { p.stop() }
        d.loop = nil
        connect(d, s.file.processingFormat)
        d.song = s
        d.eq.globalGain = s.gainDB
        let sr = s.file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, from) * sr)
        let count = AVAudioFrameCount(max(0, s.file.length - startFrame))
        d.segStart = Double(startFrame) / sr
        d.lastPos = d.segStart
        guard count > 0 else { return }
        let gen = d.generation
        let p = d.node
        p.volume = 1
        p.scheduleSegment(s.file, startingFrame: startFrame, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self, weak d] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if let self, let d, d.generation == gen, d.node === p { self.deckFinished(d) } } }
        }
        p.play(at: time)
    }

    /// Part of a song as a buffer (read from a separate copy of the file, so the playing one is not disturbed).
    private func readAudio(_ s: Prepared, from: Double, frames: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard frames > 0, let f = try? AVAudioFile(forReading: s.url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        f.framePosition = AVAudioFramePosition(max(0, from) * f.processingFormat.sampleRate)
        guard (try? f.read(into: buf, frameCount: AVAudioFrameCount(frames))) != nil, buf.frameLength > 0 else { return nil }
        return buf
    }

    /// Queues a roll on the deck's second player: the beat at `from`, repeated in the given lengths (in beats).
    private func scheduleRoll(_ d: Deck, _ s: Prepared, from: Double, lengths: [Double], period: Double) -> Bool {
        let sr = s.file.processingFormat.sampleRate
        let p = d.fx
        p.stop()
        var ok = false
        var lastLen = -1.0
        var buf: AVAudioPCMBuffer?
        for len in lengths {
            if len != lastLen {
                // every length repeats from where the roll started, as a DJ's roll does
                buf = readAudio(s, from: from, frames: AVAudioFramePosition(len * period * sr))
                lastLen = len
            }
            if let buf { p.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil); ok = true }
        }
        return ok
    }

    /// The beats just before `pos`, reversed, on the deck's second player (the backspin).
    private func scheduleBackspin(_ d: Deck, _ s: Prepared, before pos: Double, period: Double) -> Bool {
        let sr = s.file.processingFormat.sampleRate
        let len = 2 * period
        guard let buf = readAudio(s, from: max(0, pos - len), frames: AVAudioFramePosition(len * sr)), let ch = buf.floatChannelData else { return false }
        let n = Int(buf.frameLength)
        for c in 0..<Int(buf.format.channelCount) {
            var i = 0, j = n - 1
            while i < j { let t = ch[c][i]; ch[c][i] = ch[c][j]; ch[c][j] = t; i += 1; j -= 1 }
        }
        d.fx.stop()
        d.fx.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        return true
    }

    private func startCold(_ p: Prepared) {
        ensureRunning()
        prepared[p.track.id] = nil
        reset(b)
        a.input.outputVolume = 0
        schedule(a, p, from: p.hook, at: nil)
        if !playing { engine.pause() }
        let input = a.input
        ramp(0.6) { x in input.outputVolume = x }
        host?.djStarted(p, mixed: false)
        prepareAhead()
    }

    private var ramps: [(start: Double, length: Double, apply: (Float) -> Void)] = []
    private func ramp(_ seconds: Double, _ apply: @escaping (Float) -> Void) {
        ramps.append((AVAudioTime.seconds(forHostTime: mach_absolute_time()), seconds, apply))
    }
    private func applyRamps() {
        let t = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        ramps = ramps.filter { r in
            let x = Float(min(1, (t - r.start) / r.length))
            r.apply(x)
            return x < 1
        }
    }

    private func position(_ d: Deck) -> Double {
        let p = d.node
        if let rt = p.lastRenderTime, let pt = p.playerTime(forNodeTime: rt), pt.sampleRate > 0 {
            let st = pt.sampleTime
            if let l = d.loop, d.main == l.player {
                if let cb = l.contBase, st >= cb { d.lastPos = l.contStart + Double(st - cb) / pt.sampleRate }
                else if st >= 0 { d.lastPos = l.start + Double(st % l.frames) / pt.sampleRate }
            } else {
                let v = d.segStart + Double(st) / pt.sampleRate
                if v >= d.segStart - 0.001 { d.lastPos = v }
            }
        }
        return d.lastPos
    }

    private func nextBeat(_ g: BeatGrid, after t: Double) -> Double {
        g.anchor + ((t - g.anchor) / g.period).rounded(.up) * g.period
    }

    private func deckFinished(_ d: Deck) {
        guard d === a else { return }
        if running != nil { finishMix(); return }
        guard let h = host, h.queue.indices.contains(h.index + 1) else { host?.djEnded(); return }
        h.djAdvance(to: h.index + 1, mixed: false)
        play(h.current)
    }

    // MARK: planning the change-over

    private var clip: Double { host?.party?.keep == true ? 0 : (host?.party?.clip ?? 0) }

    /// Which kind of change comes next, from the mix style (Settings: Smooth, Club, Hype or Auto), never the same twice in a row.
    private func chooseChange(matched: Bool, hasBeats: Bool, slow: Bool) -> DJChange {
        if let f = forced {
            forced = nil
            if f.blends && !matched { host?.djStatus("Tempos too far apart for \(f.name). Echo out instead."); return .echoOut }
            if f.needsBeats && !hasBeats { return .echoOut }
            return f
        }
        let style = UserDefaults.standard.string(forKey: "mixStyle") ?? "auto"
        var pool: [DJChange]
        switch style {
        case "smooth": pool = matched ? [.longBlend, .bassSwap, .filterOut, .filterIn] : [.echoOut, .reverbWash]
        case "club": pool = matched ? [.bassSwap, .filterIn, .filterOut, .longBlend, .bassSwap] : [.echoOut, .loopRoll, .dropCut, .reverbWash]
        case "hype": pool = matched ? [.bassSwap, .filterIn, .loopRoll, .backspin, .brake, .dropCut] : [.loopRoll, .brake, .backspin, .dropCut, .echoOut]
        default:
            if matched {
                pool = slow ? [.longBlend, .bassSwap, .filterOut] : [.bassSwap, .filterIn, .filterOut, .longBlend]
                if mixCount % 4 == 3 { pool += [.loopRoll, .dropCut, .backspin] }
            } else {
                pool = slow ? [.reverbWash, .echoOut] : [.echoOut, .loopRoll, .dropCut, .reverbWash]
                if mixCount % 5 == 4 { pool += [.brake, .backspin] }
            }
        }
        pool = pool.filter { (!$0.blends || matched) && (!$0.needsBeats || hasBeats) && $0 != lastChange }
        if pool.isEmpty { pool = [DJChange.echoOut, .dropCut].filter { $0 != lastChange } }
        return pool.randomElement() ?? .echoOut
    }

    private func makePlan(soon: Bool = false, manual isManual: Bool = false) -> Mix? {
        guard let h = host, let s = a.song, a.loop == nil || a.loop?.contBase != nil, h.queue.indices.contains(h.index + 1) else { return nil }
        if !soon { pickClosestTempo() }
        guard let n = prepared[h.queue[h.index + 1].id] else { return nil }
        let pos = position(a)
        let end = s.duration - 3
        let gA = s.grid, gB = n.grid
        var factor = 1.0, ratio = 0.0
        if let gA, let gB, gA.sure, gB.sure {
            let tempoA = gA.bpm * Double(a.rate)
            for f in [1.0, 2.0, 0.5] {
                let r = tempoA / (gB.bpm * f)
                if ratio == 0 || abs(log(r)) < abs(log(ratio)) { ratio = r; factor = f }
            }
        }
        let matched = ratio > 0 && abs(ratio - 1) <= 0.08
        var change = isManual ? (matched ? DJChange.bassSwap : .dropCut) : chooseChange(matched: matched, hasBeats: gA != nil, slow: (gA?.bpm ?? 120) < 95)
        if isManual { forced = nil }
        if isManual && !matched, let gA {
            // a hand-made crossfade between songs whose tempos don't meet: no tempo change, the new one from its hook
            let start = nextBeat(gA, after: pos + 0.45)
            return Mix(change: .bassSwap, startA: start, dropA: start + 16 * gA.period, bStart: n.hook, bPeriod: n.grid?.period ?? gA.period,
                       rateB: 1, beats: 16, total: 20, matched: false, incoming: n)
        }
        if change.blends, let gA, let gB {
            let perA = gA.period, perB = gB.period / factor
            let phrase = 16.0 * perA
            var beats = change == .longBlend ? 32.0 : 16.0
            while beats > 4 && n.hook - beats * perB < 0 { beats /= 2 }
            if n.hook - beats * perB >= 0 {
                var startA: Double
                if soon {
                    startA = nextBeat(gA, after: pos + 0.45)
                } else {
                    // the change lands on a phrase boundary counted from the hook (choruses come in 8 and 16 bars)
                    var swap: Double
                    if clip > 0 {
                        swap = s.hook + max(1, (clip / phrase).rounded()) * phrase
                    } else {
                        swap = s.hook + ((end - s.hook) / phrase).rounded(.down) * phrase
                        if swap < s.hook + phrase { swap = gA.snap(end - 4 * perA) }
                    }
                    swap = min(swap, gA.snap(end - 2 * perA))
                    startA = swap - beats * perA
                }
                if startA > pos + 0.4 {
                    let tail: Double = change == .longBlend ? 8 : change == .bassSwap ? 4 : 2
                    return Mix(change: change, startA: startA, dropA: startA + beats * perA, bStart: n.hook - beats * perB, bPeriod: perB,
                               rateB: Float(ratio), beats: beats, total: beats + tail, matched: true, incoming: n)
                }
            }
            change = .echoOut
        }
        if change.needsBeats && gA == nil { change = .dropCut }
        // a change that doesn't blend: an effect on the old song, then the new one drops in at its hook
        let per = gA?.period ?? 0.5
        let fx = change.fxBeats
        var drop: Double
        if soon {
            drop = gA.map { nextBeat($0, after: pos + 0.45 + fx * $0.period) } ?? pos + 0.6
        } else {
            drop = clip > 0 ? s.hook + clip : end - 1
            if let gA {
                let phrase = 16 * gA.period
                if clip > 0 { drop = s.hook + max(1, (clip / phrase).rounded()) * phrase }
                drop = gA.snap(drop)
            }
            drop = max(min(drop, end - 1), pos + 0.5 + fx * per)
        }
        return Mix(change: change, startA: drop - fx * per, dropA: drop, bStart: n.hook, bPeriod: n.grid?.period ?? 0.5,
                   rateB: 1, beats: 0, total: 0, matched: false, incoming: n)
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
        guard h.queue.indices.contains(next), (distance(h.queue[next]) ?? 1) > log(1.08), next + 1 < h.queue.count else { return }
        var best: Int?, bestD = 1.0
        for i in (next + 1)..<min(h.queue.count, next + 3) {
            if let d = distance(h.queue[i]), d <= log(1.08), d < bestD { best = i; bestD = d }
        }
        if let best { h.djMoveUp(best, to: next) }
    }

    // MARK: every 25 ms

    private func step() {
        guard let h = host, h.party != nil else { return }
        applyRamps()
        guard let s = a.song else { return }
        let pos = position(a)
        if playing && abs(pos - lastReport) >= 0.25 { lastReport = pos; h.djTime(pos, s.duration) }
        ticks += 1
        if ticks % 2 == 0 { updateLive(pos) }
        guard playing else { return }
        glide()
        stepRoll()
        stepLoop()
        if running == nil {
            if plan == nil, a.loop == nil || a.loop?.contBase != nil, nextReady { plan = makePlan() }
            if let p = plan, pos >= p.startA - 0.4 { plan = nil; begin(p, posA: pos) }
        } else if let m = running {
            mixing(m)
        }
    }

    private func stepRoll() {
        guard let r = roll else { return }
        let t = now
        if t >= r.start && t < r.end { a.node.volume = Float(max(0, 1 - (t - r.start) / 0.04)) }
        if t >= r.end {
            a.node.volume = Float(min(1, (t - r.end) / 0.04))
            a.fx.volume = Float(max(0, 1 - (t - r.end) / 0.04))
            if t >= r.end + 0.08 { roll = nil; live.rolling = false; a.node.volume = 1; a.fx.stop(); a.fx.volume = 1 }
        }
    }

    /// When the loop starts, the main player hands over to the loop player.
    private func stepLoop() {
        guard var l = a.loop, !l.switched else { return }
        let t = now
        if t >= l.startSec { a.node.volume = Float(max(0, 1 - (t - l.startSec) / 0.04)) }
        if t >= l.startSec + 0.06 {
            a.node.stop()
            a.node.volume = 1
            a.main = l.player
            l.switched = true
            a.loop = l
        }
    }

    private func begin(_ p: Mix, posA: Double) {
        let n = p.incoming
        prepared[n.track.id] = nil
        var m = p
        m.startSec = now + max(0.05, (p.startA - posA) / Double(a.rate))
        m.dropSec = m.startSec + (p.dropA - p.startA) / Double(a.rate)
        clearEffects(b)
        b.input.outputVolume = 0
        if p.change.blends {
            b.pitch.rate = p.rateB; b.rate = p.rateB
            if p.change != .filterIn { b.eq.bands[0].gain = -26 }
            if p.change == .filterIn { b.eq.bands[4].bypass = false; b.eq.bands[4].frequency = 250 }
            if p.change == .longBlend { b.eq.bands[2].gain = -6 }
            schedule(b, n, from: p.bStart, at: hostTime(m.startSec))
        } else {
            schedule(b, n, from: p.bStart, at: hostTime(m.dropSec))
            if let s = a.song, let g = s.grid {
                if p.change == .loopRoll {
                    if scheduleRoll(a, s, from: p.startA, lengths: [1, 1, 0.5, 0.5, 0.25, 0.25, 0.25, 0.25], period: g.period) {
                        a.fx.volume = 1
                        a.fx.play(at: hostTime(m.startSec))
                    }
                } else if p.change == .backspin {
                    if scheduleBackspin(a, s, before: p.startA, period: g.period) {
                        a.fx.volume = 1
                        a.fx.play(at: hostTime(m.startSec))
                    }
                }
            }
        }
        running = m
        mixCount += 1
        lastChange = p.change
        glideFrom = nil
        if live.echo { toggleEcho() }
        if live.reverb { toggleReverb() }
        if filterOn { toggleFilter() }
        host?.djStatus("Mixing · \(p.change.name)")
    }

    private func ease(_ x: Double) -> Float { let c = max(0, min(1, x)); return Float(c * c * (3 - 2 * c)) }

    private func mixing(_ m: Mix) {
        let t = now
        if m.change.blends {
            guard t >= m.startSec else { return }
            let posA = position(a), posB = position(b)
            let beat = max(0, (posB - m.bStart) / m.bPeriod)
            if m.matched { lockBeats(m, posA: posA, posB: posB) }
            if var x = manual {
                // the user (or the hand-back after letting go) holds the crossfader
                if let af = autoFrom, let g = a.song?.grid {
                    x = af.x + (1 - af.x) * min(1, (t - af.at) / (8 * g.period / Double(a.rate)))
                    manual = x
                    if x >= 1 { finishMix(); return }
                }
                a.input.outputVolume = Float(cos(x * .pi / 2))
                b.input.outputVolume = Float(sin(x * .pi / 2))
                a.eq.bands[0].gain = x >= 0.5 ? -26 : 0
                b.eq.bands[0].gain = x >= 0.5 ? 0 : -26
                b.eq.bands[4].bypass = true
                return
            }
            let half = m.beats / 2
            switch m.change {
            case .filterIn:
                b.input.outputVolume = ease(beat / half)
                b.eq.bands[4].frequency = Float(250 * pow(80.0, min(1, beat / m.beats)))      // 250 Hz → 20 kHz
                a.eq.bands[0].gain = -26 * ease((beat - half) / half)
                if beat >= m.beats { b.eq.bands[4].bypass = true }
            case .longBlend:
                b.input.outputVolume = ease(beat / half)
                a.eq.bands[2].gain = -8 * ease((beat - half) / half)
                if beat >= m.beats - 0.5 { b.eq.bands[0].gain = 0; b.eq.bands[2].gain = 0 }
            case .filterOut:
                b.input.outputVolume = ease(beat / half)
                let x = max(0, min(1, (beat - half) / half))
                a.eq.bands[3].bypass = x <= 0
                a.eq.bands[3].frequency = Float(20 * pow(60.0, x))
                if beat >= m.beats - 0.5 { b.eq.bands[0].gain = 0 }
            default:
                b.input.outputVolume = ease(beat / half)
                if beat >= m.beats - 0.5 { b.eq.bands[0].gain = 0 }                          // a touch early, so the kick is there on the 1
            }
            if beat >= m.beats {
                a.eq.bands[0].gain = -26
                a.input.outputVolume = 1 - ease((beat - m.beats) / max(1, m.total - m.beats))
            }
            if beat >= m.total { finishMix() }
            return
        }
        // the changes that don't blend
        guard t >= m.startSec else { return }
        let fxLen = max(0.001, m.dropSec - m.startSec)
        let e = min(1, (t - m.startSec) / fxLen)
        let dropped = t >= m.dropSec
        switch m.change {
        case .reverbWash:
            a.reverb.wetDryMix = Float(100 * e)
            if dropped { a.node.volume = 0 }
        case .brake:
            a.pitch.rate = Float(max(0.05, 1 - 0.95 * e)); a.pitch.pitch = Float(-1800 * e)
            a.input.outputVolume = e > 0.8 ? Float(max(0, 1 - (e - 0.8) / 0.2)) : 1
        case .loopRoll:
            a.node.volume = Float(max(0, 1 - (t - m.startSec) / 0.04))
            a.eq.bands[3].bypass = false
            a.eq.bands[3].frequency = Float(20 * pow(40.0, e))
            if dropped { a.fx.volume = 0 }
        case .backspin:
            a.node.volume = 0
            a.pitch.rate = 2; a.pitch.pitch = 500
            a.input.outputVolume = Float(max(0, 1 - e * 0.6))
            if dropped { a.fx.volume = 0 }
        case .echoOut:
            if dropped && a.delay.wetDryMix == 0 {
                let per = a.song?.grid?.period ?? 0.5
                a.delay.delayTime = min(2, per * 0.75 / Double(a.rate)); a.delay.feedback = 45; a.delay.wetDryMix = 45
                a.node.volume = 0
            }
        default:
            if dropped { a.node.volume = 0; a.fx.volume = 0 }
        }
        if dropped {
            let fadeIn = m.change == .echoOut ? 0.75 * m.bPeriod : 0.04
            b.input.outputVolume = Float(min(1, (t - m.dropSec) / fadeIn))
            if t - m.dropSec > 1.2 { finishMix() }
        }
    }

    /// Keeps the two songs' beats together: if the incoming one drifts ahead or behind, it is nudged (at most 3%).
    private func lockBeats(_ m: Mix, posA: Double, posB: Double) {
        guard let gA = a.song?.grid, a.loop == nil else { return }
        let phA = gA.phase(posA)
        let x = (posB - m.bStart) / m.bPeriod
        var e = (x - x.rounded(.down)) - phA
        if e > 0.5 { e -= 1 }
        if e < -0.5 { e += 1 }
        live.locked = abs(e) < 0.04
        let wallBeat = gA.period / Double(a.rate)
        let nudge = max(-0.03, min(0.03, -e * wallBeat / 0.8))
        let r = m.rateB * Float(1 + nudge)
        if abs(r - b.pitch.rate) > 0.0005 { b.pitch.rate = r }
        b.rate = m.rateB
    }

    /// The user pulled the crossfader all the way back: the incoming song stops and waits for the next change.
    private func cancelMix() {
        guard let m = running else { manual = nil; return }
        running = nil
        manual = nil; autoFrom = nil
        reset(b, keepFile: true)
        prepared[m.incoming.track.id] = m.incoming
        a.input.outputVolume = 1
        a.eq.bands[0].gain = 0
        live.locked = nil
        host?.djStatus("Mix cancelled")
    }

    private func finishMix() {
        guard let h = host, let n = b.song, let m = running else { running = nil; plan = nil; return }
        let rateB = b.pitch.rate
        running = nil
        plan = nil
        manual = nil; autoFrom = nil
        live.locked = nil
        // the old deck rings out its echo or reverb, then is cleared
        let old = a
        old.generation += 1
        if m.change == .echoOut || m.change == .reverbWash {
            let gen = old.generation
            for p in old.players { p.stop() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self, old.generation == gen, old !== self.a else { return }
                self.reset(old)
            }
        } else {
            reset(old)
        }
        a = b
        b = old
        a.input.outputVolume = 1
        for band in a.eq.bands.prefix(3) { band.gain = 0 }
        a.eq.bands[4].bypass = true
        if abs(rateB - 1) > 0.002 { glideFrom = rateB; glideStartPos = position(a) } else { a.pitch.rate = 1; a.rate = 1 }
        h.djAdvance(to: h.index + 1, mixed: true)
        h.djStarted(n, mixed: true)
        prepareAhead()
    }

    /// After a mix the new song slides back to its own tempo over 16 of its beats.
    private func glide() {
        guard let from = glideFrom, let g = a.song?.grid, running == nil else { return }
        let x = min(1, (position(a) - glideStartPos) / (16 * g.period))
        let r = from + (1 - from) * Float(x)
        a.pitch.rate = r; a.rate = r
        if x >= 1 { glideFrom = nil; a.pitch.rate = 1; a.rate = 1 }
    }

    // MARK: the DJ view

    private func updateLive(_ pos: Double) {
        let t = CACurrentMediaTime()
        for d in [a, b] {
            var v = DJLive.DeckView()
            if let s = d.song {
                v.track = s.track
                v.bpm = s.grid.map { $0.bpm * Double(d.pitch.rate) }
                v.pitchPct = (Double(d.pitch.rate) - 1) * 100
                v.pos = d === a ? pos : position(d)
                v.at = t
                v.rate = Double(d.pitch.rate)
                v.playing = playing && (d === a || running != nil && now >= (running!.change.blends ? running!.startSec : running!.dropSec))
                v.dur = s.duration
                v.hook = s.hook
                v.anchor = s.grid?.anchor
                v.period = s.grid?.period
                v.sure = s.grid?.sure ?? false
                v.wave = s.wave
                v.onAir = d === a
                if d === a, let p = plan ?? running { v.mixAt = p.startA }
            } else if d === b, let h = host, h.queue.indices.contains(h.index + 1), let n = prepared[h.queue[h.index + 1].id] {
                // the next song waits on the other deck, cued at the point it will start from
                let p = plan
                v.track = n.track
                v.bpm = n.grid?.bpm
                v.pos = p?.bStart ?? n.hook
                v.at = t
                v.dur = n.duration
                v.hook = n.hook
                v.anchor = n.grid?.anchor
                v.period = n.grid?.period
                v.sure = n.grid?.sure ?? false
                v.wave = n.wave
            }
            v.meters = d.song != nil && playing ? d.meter.value : [0, 0, 0]
            live.decks[d.number - 1] = v
        }
        // the crossfader: where the mix is
        var x = 0.0
        if let m = running {
            if let mx = manual { x = mx }
            else if m.change.blends {
                let beat = max(0, (position(b) - m.bStart) / m.bPeriod)
                x = min(1, beat / max(1, m.total))
            } else {
                x = now >= m.dropSec ? 1 : 0
            }
        }
        live.fader = a.number == 1 ? x : 1 - x
        live.mixing = running != nil
        live.canMix = running == nil && a.loop == nil && nextReady && playing
        if let g = a.song?.grid {
            let k = Int(((pos - g.anchor) / g.period).rounded(.down))
            live.beat = ((k % 4) + 4) % 4
        }
        // what's coming
        if let m = running {
            let left = m.change.blends ? (m.dropA - pos) / (a.song?.grid?.period ?? 0.5) : (m.dropSec - now) / ((a.song?.grid?.period ?? 0.5) / Double(a.rate))
            live.countdown = left > 0.5 ? "\(m.change.name): drop in \(Int(left.rounded())) beats" : m.change.name
            live.next = m.change.name
        } else if let p = plan {
            live.next = p.change.name
            let beats = (p.startA - pos) / (a.song?.grid?.period ?? 0.5)
            live.countdown = beats <= 32 ? "\(p.change.name) in \(max(0, Int(beats.rounded()))) beats" : "\(p.change.name) at \(clock(p.startA))"
        } else {
            live.next = forced?.name
            live.countdown = a.loop != nil ? "Looping \(a.loop!.beats) beats" : (nextReady ? nil : "Getting the next song ready…")
        }
    }

    // MARK: interruptions

    private func configurationChanged() {
        // headphones plugged or unplugged: the engine stopped; carry on from the same place
        guard a.song != nil else { return }
        if running != nil { finishMix() }
        plan = nil
        roll = nil
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
