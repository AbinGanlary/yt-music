import Foundation
import AVFoundation

/// A song's tempo and where its beats fall, worked out from the audio around the hook.
struct BeatGrid: Equatable, Sendable {
    var bpm: Double
    var anchor: Double          // a beat, in seconds from the start of the song
    var sure: Bool              // the beats held steady across the whole stretch (no off-beat flips)
    var period: Double { 60 / bpm }

    /// The beat nearest to a moment in the song.
    func snap(_ t: Double) -> Double { anchor + ((t - anchor) / period).rounded() * period }
    /// How far into the current beat a moment is, 0..<1.
    func phase(_ t: Double) -> Double {
        let x = (t - anchor) / period
        return x - x.rounded(.down)
    }
}

/// What a song needs before it can be mixed: the file, where its hook is, its beats and how loud it is.
struct SongAnalysis: Sendable {
    var grid: BeatGrid?
    var gainDB: Float           // brings every song to about the same loudness
    var duration: Double
}

enum BeatTracker {
    /// Tempo and beat phase of mono samples. `rate` is their sample rate. Tempos 70–180 BPM are considered.
    /// The same steps as the PC prototype: onset strength from a low band and the full band, a comb over the tempos
    /// (slightly preferring ~115 BPM), refined to 0.05 BPM, then the beat phase in the first and last 25 seconds
    /// compared, which shows whether the grid really holds.
    static func analyze(_ x: [Float], rate: Double) -> (bpm: Double, phase: Double, drift: Double)? {
        let hop = max(32, Int((rate / 86).rounded()))
        let n = x.count / hop
        guard n > 400 else { return nil }
        let fps = rate / Double(hop)
        var env = [Float](repeating: 0, count: n)
        var lp: Float = 0, prevA: Float = 0, prevB: Float = 0
        let k: Float = Float(min(0.5, 0.12 * 11025 / rate))
        for i in 0..<n {
            var ea: Float = 0, eb: Float = 0
            let base = i * hop
            for j in 0..<hop {
                let s = x[base + j]
                lp += k * (s - lp)
                ea += lp * lp
                eb += s * s
            }
            let a = log(1e-6 + ea), b = log(1e-6 + eb)
            env[i] = max(0, a - prevA) + 0.5 * max(0, b - prevB)
            prevA = a; prevB = b
        }
        var o = [Float](repeating: 0, count: n)
        var acc: Float = 0
        let w = 16
        for i in 0..<n {
            acc += env[i]
            if i >= w { acc -= env[i - w] }
            o[i] = max(0, env[i] - acc / Float(min(i + 1, w)))
        }
        func comb(_ bpm: Double, _ lo: Int = 0, _ hi: Int? = nil) -> (score: Double, phase: Double) {
            let hi = hi ?? n
            let period = 60 / bpm * fps
            var best = -1.0, bestPh = 0.0
            var ph = 0.0
            while ph < period {
                var s = 0.0, c = 0
                var t = Double(lo) + ph
                while t < Double(hi - 2) {
                    let i = Int(t), f = t - Double(i)
                    s += Double(o[i]) * (1 - f) + Double(o[i + 1]) * f
                    c += 1
                    t += period
                }
                let sc = s / Double(max(1, c))
                if sc > best { best = sc; bestPh = ph }
                ph += 0.25
            }
            return (best, bestPh / fps)
        }
        var top = 120.0, topScore = -1.0
        var bpm = 70.0
        while bpm <= 180 {
            let c = comb(bpm)
            let prior = exp(-0.5 * pow(log2(bpm / 115) / 0.6, 2))
            let s = c.score * (0.7 + 0.3 * prior)
            if s > topScore { topScore = s; top = bpm }
            bpm += 0.5
        }
        var best = (bpm: top, score: comb(top).score, phase: comb(top).phase)
        var b = top - 0.6
        while b <= top + 0.6 {
            let c = comb(b)
            if c.score > best.score { best = (b, c.score, c.phase) }
            b += 0.05
        }
        let per = 60 / best.bpm
        let q = min(n / 2, Int(25 * fps))
        let p1 = comb(best.bpm, 0, q).phase
        let p2 = comb(best.bpm, n - q, n).phase + Double(n - q) / fps
        var d = (p2 - p1).truncatingRemainder(dividingBy: per)
        if d < 0 { d += per }
        if d > per / 2 { d -= per }
        return (best.bpm, best.phase, d)
    }

    /// Reads about 70 seconds of the file starting a little before the hook, and works out its beats and loudness.
    /// Runs off the main thread; opens its own copy of the file.
    static func analyzeFile(_ url: URL, hook: Double) -> SongAnalysis? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        let duration = Double(file.length) / sr
        let from = max(0, min(hook - 14, duration - 75))
        let frames = AVAudioFrameCount(min(Double(file.length) - from * sr, 75 * sr))
        guard frames > AVAudioFrameCount(sr * 20),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return SongAnalysis(grid: nil, gainDB: 0, duration: duration) }
        file.framePosition = AVAudioFramePosition(from * sr)
        do { try file.read(into: buf, frameCount: frames) } catch { return SongAnalysis(grid: nil, gainDB: 0, duration: duration) }
        guard let ch = buf.floatChannelData else { return nil }
        let chans = Int(buf.format.channelCount), len = Int(buf.frameLength)
        // mono, a quarter of the sample rate (an average of each four samples)
        let dec = 4
        var mono = [Float](repeating: 0, count: len / dec)
        var sq: Double = 0
        for i in 0..<mono.count {
            var s: Float = 0
            for c in 0..<chans { for j in 0..<dec { s += ch[c][i * dec + j] } }
            s /= Float(chans * dec)
            mono[i] = s
            sq += Double(s * s)
        }
        let rms = sqrt(sq / Double(max(1, mono.count)))
        // about -14 dB RMS, never more than 4 dB louder or 8 dB quieter
        let gain = Float(max(-8, min(4, -14 - 20 * log10(max(1e-5, rms)))))
        guard let r = analyze(mono, rate: sr / Double(dec)) else { return SongAnalysis(grid: nil, gainDB: gain, duration: duration) }
        let grid = BeatGrid(bpm: r.bpm, anchor: from + r.phase, sure: abs(r.drift) < 0.045)
        return SongAnalysis(grid: grid, gainDB: gain, duration: duration)
    }
}
