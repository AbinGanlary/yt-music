import SwiftUI
import Combine
import AVFoundation
import MediaPlayer

private let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

/// The playback position. It changes four times a second, so it lives apart from PlayerModel:
/// only the views that show the time (scrubber, progress bar, lyrics) redraw on every tick, not every list and menu.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
}

enum LyricsState {
    case idle
    case loading
    case none
    case ready(Lyrics)
}

/// Plays real songs: the engine finds a stream address, AVPlayer streams it, and if YouTube refuses the stream
/// the song is downloaded first (over the app's IPv4 client) and played from a file.
@MainActor
final class PlayerModel: ObservableObject {
    @Published var queue: [Track] = sampleTracks
    @Published var index = 0
    @Published var isPlaying = false
    let time = PlaybackClock()
    var elapsed: Double { get { time.elapsed } set { time.elapsed = newValue } }
    var duration: Double { get { time.duration } set { if abs(time.duration - newValue) > 0.01 { time.duration = newValue } } }
    @Published var naming = false                      // the "New playlist" name prompt
    let lib = Library()
    let downloads = Downloads()
    private var pendingTrack: Track?
    @Published var message: String?
    @Published var status = "Nothing played yet"
    @Published var lyricsState: LyricsState = .idle
    @Published var autoplay = true
    @Published var speed: Float = 1
    @Published var shuffle = false
    @Published var renaming: UUID?                       // the playlist whose name is being changed
    @Published var repeatMode = 0                      // 0 off, 1 all, 2 one
    @Published var artAccent: Color?                    // the accent when Settings → Appearance is set to "Artwork"
    @Published var sleepLabel: String?                  // "15 min", "End of song", or nil when off
    @Published var shareItem: ShareItem?                // a tagged .m4a ready for the share sheet

    private let engine = EngineHost.shared
    private let player = AVPlayer()
    private var loadTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var lastInfoUpdate = 0.0
    private var nowArtwork: MPMediaItemArtwork?
    private var nowArtworkFor: String?
    private var playingTrack: Track?
    private var listened = 0.0
    private var lastSec = 0.0
    private var radioSeen = Set<String>()
    private var lyricsFor: String?
    private var sleepTask: Task<Void, Never>?
    private var expected = 0.0                           // how long YouTube says this song is (0 = unknown)
    private var endedHandled = false
    private var extending = false
    private var fallbackStreak = 0                      // songs in a row whose stream was refused (Auto then downloads first)
    private var songsSinceStreamTry = 0
    private var prefetch: (id: String, task: Task<(file: URL, info: StreamInfo)?, Never>)?
    /// Download-first: always, or in Auto after two refused streams in a row (streaming is tried again every 8th song).
    private var downloadMode: Bool { startMode == "download" || (startMode == "auto" && fallbackStreak >= 2) }
    private var orderBackup: [Track] = []              // the queue's order before shuffle was switched on
    private var recentSignals: [(artist: String, skipped: Bool)] = []
    private var dynamicQueue: Bool { UserDefaults.standard.object(forKey: "dynamic") == nil || UserDefaults.standard.bool(forKey: "dynamic") }
    private var quality: String { UserDefaults.standard.string(forKey: "quality") ?? "high" }
    private var downloadQuality: String { UserDefaults.standard.string(forKey: "dlQuality") ?? "high" }
    private var startMode: String { UserDefaults.standard.string(forKey: "playbackMode") ?? "auto" }
    private var sleepAtEnd = false
    private var segments: [[Double]] = []               // SponsorBlock: parts to skip, [start, end]
    private var sponsorBlockOn: Bool { UserDefaults.standard.bool(forKey: "sponsorBlock") }

    var current: Track { queue[min(index, queue.count - 1)] }
    var liked: Set<String> { lib.likedIDs }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            let s = t.seconds
            Task { @MainActor in self?.tick(s) }
        }
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [weak self] _ in Task { @MainActor in self?.songEnded() } }
            .store(in: &bag)
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                guard let self = self else { return }
                self.isPlaying = (s != .paused)
                self.updateNowPlaying(force: true)
            }
            .store(in: &bag)
        lib.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        downloads.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        setupRemote()
    }

    // MARK: choosing what plays

    func play(_ t: Track) {
        if let i = queue.firstIndex(of: t) { index = i } else { queue.insert(t, at: min(index + 1, queue.count)); index = min(index + 1, queue.count - 1) }
        start()
    }
    /// A list of songs (search results): the tapped one plays and the rest follow.
    func play(_ t: Track, in list: [Track]) {
        flushListen()                                   // count the old song before the queue changes
        if shuffle && list.count > 1 {                  // the chosen song first, the rest shuffled
            orderBackup = list
            queue = [t] + list.filter { $0.id != t.id }.shuffled()
            index = 0
        } else {
            orderBackup = []
            queue = list
            index = list.firstIndex(of: t) ?? 0
        }
        start()
    }

    /// A station: the song plays and similar songs keep coming. If it is already playing, it carries on and only what follows changes.
    func startRadio(_ t: Track) {
        orderBackup = []
        if t.id == current.id, player.currentItem != nil {
            queue = [t]
            index = 0
        } else {
            flushListen()
            queue = [t]
            index = 0
            start()
        }
        flash("Starting radio")
        Task { await topUp(force: true, plain: true) }
    }

    func toggleShuffle() {
        shuffle.toggle()
        let cur = current
        if shuffle {
            orderBackup = queue
            queue = [cur] + queue.enumerated().filter { $0.offset != index }.map { $0.element }.shuffled()
            index = 0
        } else if !orderBackup.isEmpty {
            let known = Set(orderBackup.map { $0.id })
            queue = orderBackup + queue.filter { !known.contains($0.id) }      // radio songs added meanwhile stay at the end
            index = queue.firstIndex(where: { $0.id == cur.id }) ?? 0
            orderBackup = []
        }
        flash(shuffle ? "Shuffle on" : "Shuffle off")
    }
    func cycleRepeat() {
        repeatMode = (repeatMode + 1) % 3
        flash(["Repeat off", "Repeat all", "Repeat one"][repeatMode])
    }

    /// "Not interested": the song goes, and it is never suggested again.
    func dislike(_ t: Track) {
        if lib.toggleDislike(t) {
            if lib.isLiked(t) { lib.toggleLike(t) }
            flash("Won't suggest this again")
            if t.id == current.id {
                next()
            } else {
                let cur = current
                queue.removeAll { $0.id == t.id }
                index = queue.firstIndex(where: { $0.id == cur.id }) ?? 0
            }
        } else {
            flash("Removed from not interested")
        }
    }
    func next() {
        if queue.isEmpty { return }
        if index + 1 < queue.count { index += 1; start(); return }
        if repeatMode == 1 { index = 0; start(); return }                      // repeat all: back to the first song
        guard autoplay else { player.pause(); flash("End of the queue"); return }
        Task {                                                                  // the end of the queue: fetch similar songs first
            await topUp(force: true)
            if index + 1 < queue.count { index += 1; start() } else { player.pause(); flash("End of the queue") }
        }
    }
    func previous() {
        if elapsed > 3 { seek(0) } else { index = (index + queue.count - 1) % queue.count; start() }
    }
    func toggle() {
        if player.currentItem == nil { start(); return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }
    func seek(_ fraction: Double) {
        let d = duration > 0 ? duration : Double(current.seconds)
        let target = max(0, min(1, fraction)) * d
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        elapsed = target
    }
    func toggleLike(_ t: Track) {
        let now = lib.toggleLike(t)
        flash(now ? "Added to liked" : "Removed from liked")
        if now && UserDefaults.standard.bool(forKey: "smartDl") { saveOffline(t, quiet: true) }      // Smart downloads
    }
    func playNext(_ t: Track) {
        guard t != current else { return }
        let cur = current
        queue.removeAll { $0 == t }
        index = queue.firstIndex(of: cur) ?? 0
        queue.insert(t, at: min(index + 1, queue.count))
        flash("Playing next: \(t.title)")
    }
    // MARK: playlists
    /// Asks for a name; the song (if any) goes into the new playlist.
    func requestPlaylist(for t: Track?) { pendingTrack = t; naming = true }
    func createPlaylist(named name: String) {
        let p = lib.newPlaylist(name, with: pendingTrack)
        flash("Created \(p.name)")
        pendingTrack = nil
    }
    func cancelPlaylist() { pendingTrack = nil }
    func add(_ t: Track, to p: Playlist) {
        flash(lib.add(t, to: p.id) ? "Added to \(p.name)" : "Already in \(p.name)")
    }
    func addToQueue(_ t: Track) {
        if !queue.contains(t) { queue.append(t) }
        flash("Added to queue")
    }

    func notify(_ text: String) { flash(text) }

    /// Saves a song for offline listening.
    func saveOffline(_ t: Track, quiet: Bool = false) {
        if downloads.has(t.id) { if !quiet { flash("Already saved") }; return }
        if t.id.count < 11 { if !quiet { flash("This is a sample song") }; return }
        if !quiet { flash("Downloading \(t.title)…") }
        Task {
            do {
                let info = try await engine.stream(t.id, quality: downloadQuality)
                let tmp = try await download(info, t, quiet: true)
                let secs = info.approxMs.map { $0 / 1000 } ?? t.seconds        // the real length, so a saved copy plays right
                let saved = Track(id: t.id, title: t.title, artist: t.artist, seconds: secs, thumbnail: t.thumbnail, album: t.album, video: t.video)
                try downloads.adopt(tmp, track: saved)
                if !quiet { flash("Saved for offline: \(t.title)") }
            } catch {
                if !quiet { flash("Download failed: " + String(error.localizedDescription.prefix(80))) }
            }
        }
    }
    /// Makes a tagged .m4a (title, artist, album, cover) and opens the share sheet, where "Save to Files" is one of the actions.
    func saveToFiles(_ t: Track) {
        if t.id.count < 11 { flash("This is a sample song"); return }
        flash("Preparing the file…")
        Task {
            do {
                let audio: Data
                if let local = downloads.url(for: t.id) {
                    audio = try Data(contentsOf: local)
                } else {
                    let info = try await engine.stream(t.id, quality: downloadQuality)
                    let tmp = try await download(info, t, quiet: true)
                    audio = try Data(contentsOf: tmp)
                    try? FileManager.default.removeItem(at: tmp)
                }
                var cover: Data?
                if let u = sizedURL(t.thumbnail?.absoluteString, 544), let (d, _) = try? await URLSession.shared.data(from: u) { cover = d }
                let tagged = M4ATagger.tag(audio, title: t.title, artist: t.artist, album: t.album, cover: cover)
                let safe = "\(t.artist.isEmpty ? "" : t.artist + " - ")\(t.title)".components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: " ")
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent(String(safe.prefix(100)) + ".m4a")
                try tagged.write(to: file, options: .atomic)
                shareItem = ShareItem(url: file)
            } catch {
                flash("Couldn't prepare the file: " + String(error.localizedDescription.prefix(80)))
            }
        }
    }

    func removeDownload(_ t: Track) { downloads.remove(t); flash("Removed download") }
    private func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in if self?.message == text { self?.message = nil } }
    }

    // MARK: getting the audio

    private func start() {
        loadTask?.cancel()
        flushListen()
        let t = current
        playingTrack = t
        listened = 0
        lastSec = 0
        Task { await updateArtAccent(t) }
        Task { await loadNowArtwork(t) }
        lib.addHistory(t)
        extendQueueIfNeeded(t)
        segments = []
        expected = 0
        endedHandled = false
        if sponsorBlockOn { Task { await loadSegments(t) } }
        elapsed = 0
        duration = Double(t.seconds)
        status = "Finding the song…"
        player.pause()
        player.replaceCurrentItem(with: nil)
        updateNowPlaying(force: true)
        loadTask = Task { await load(t) }
    }

    /// A music video plays as its song version (clean audio, album art), like YouTube Music does. Falls back to the video.
    private func resolveSong(_ t: Track) async -> Track {
        guard t.video == true, t.id.count >= 11 else { return t }
        let path = "/api/counterpart/\(t.id)?title=\(EngineHost.enc(t.title))&artist=\(EngineHost.enc(t.artist))&dur=\(EngineHost.enc(clock(Double(t.seconds))))"
        guard let raw = try? await engine.get(path, as: RawTrack?.self), let song = Track(raw), song.id != t.id else { return t }
        if queue.indices.contains(index), queue[index].id == t.id { queue[index] = song }
        playingTrack = song
        duration = Double(song.seconds)
        Task { await updateArtAccent(song) }
        Task { await loadNowArtwork(song) }
        return song
    }

    private func load(_ original: Track) async {
        let t = await resolveSong(original)
        if Task.isCancelled { return }
        if let local = downloads.url(for: t.id) {                  // a saved copy plays with no network
            expected = Double(downloads.tracks.first(where: { $0.id == t.id })?.seconds ?? 0)
            player.replaceCurrentItem(with: AVPlayerItem(url: local))
            player.play()
            status = "Playing a saved copy"
            return
        }
        // a copy fetched ahead of time while the previous song played (download-first only)
        if downloadMode, let p = prefetch, p.id == t.id, let got = await p.task.value {
            prefetch = nil
            expected = Double(got.info.approxMs ?? 0) / 1000
            player.replaceCurrentItem(with: AVPlayerItem(url: got.file))
            player.play()
            status = "Playing a copy fetched ahead of time"
            return
        }
        do {
            let info = try await engine.stream(t.id, quality: quality)
            try Task.checkCancellation()
            expected = Double(info.approxMs ?? 0) / 1000
            status = "Got an address (\((info.bitrate ?? 0) / 1000) kbps). Trying to stream…"
            let mode = startMode                       // "auto", "stream" (never downloads) or "download" (waits for the whole song first)
            var tryStreaming = mode != "download"
            if mode == "auto" && fallbackStreak >= 2 {  // streams keep being refused: download first, but look again every 8th song
                songsSinceStreamTry += 1
                tryStreaming = songsSinceStreamTry % 8 == 0
            }
            if tryStreaming, let url = URL(string: info.url), let item = await tryStream(url) {
                fallbackStreak = 0
                status = "Streaming directly from YouTube"
                // YouTube sometimes accepts the first bytes and refuses later ones: watch for that and switch to a download.
                for _ in 0..<80 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled || player.currentItem !== item { return }
                    if item.status == .failed { break }
                }
                if item.status != .failed { return }
                if mode == "stream" { throw NSError(domain: "play", code: 1, userInfo: [NSLocalizedDescriptionKey: "The stream stopped, and the start mode is Stream (it never downloads)"]) }
                if mode == "auto" { fallbackStreak += 1 }
                status = "Stream stopped. Downloading instead…"
            } else {
                if mode == "auto" && tryStreaming { fallbackStreak += 1 }
                if mode == "stream" { throw NSError(domain: "play", code: 1, userInfo: [NSLocalizedDescriptionKey: "YouTube refused the stream, and the start mode is Stream (it never downloads). Change it in Settings."]) }
                status = mode == "download" ? "Downloading first…" : "Stream refused. Downloading first…"
            }
            try Task.checkCancellation()
            let file = try await download(info, t)
            try Task.checkCancellation()
            let item = AVPlayerItem(url: file)
            player.replaceCurrentItem(with: item)
            player.play()
            status = "Playing from a downloaded file"
        } catch is CancellationError {
        } catch {
            status = "Couldn't play: " + String(error.localizedDescription.prefix(180))
        }
    }

    /// Streams the address with AVPlayer; the item once it is ready to play, nil if it fails or takes too long.
    private func tryStream(_ url: URL) async -> AVPlayerItem? {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": mobileUA]])
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.play()
        for _ in 0..<40 {                                        // up to 10 seconds
            if Task.isCancelled { return nil }
            switch item.status {
            case .readyToPlay: return item
            case .failed: return nil
            default: try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        return nil
    }

    /// The whole song in a temporary file, fetched with ranged requests over IPv4.
    private func download(_ info: StreamInfo, _ t: Track, quiet: Bool = false) async throws -> URL {
        guard let url = URL(string: info.url) else { throw URLError(.badURL) }
        let chunk = 1_048_576
        var data = Data()
        var total = info.size ?? 0
        var start = 0
        while total == 0 || start < total {
            try Task.checkCancellation()
            let end = start + chunk - 1
            let r = try await v4Request(url: url, headers: ["Range": "bytes=\(start)-\(end)", "User-Agent": mobileUA], timeout: 40)
            guard r.status == 206 || r.status == 200 else { throw NSError(domain: "dl", code: r.status, userInfo: [NSLocalizedDescriptionKey: "YouTube answered \(r.status) for the audio"]) }
            if let cr = r.headers.first(where: { $0.key.lowercased() == "content-range" })?.value, let slash = cr.firstIndex(of: "/"), let n = Int(cr[cr.index(after: slash)...]) { total = n }
            data.append(r.body)
            if r.status == 200 { break }
            start += r.body.count
            if total == 0 && r.body.count < chunk { break }
            if r.body.isEmpty { break }
            if total > 0 && !quiet { status = "Downloading… \(min(100, data.count * 100 / total))%" }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(t.id).m4a")
        try data.write(to: file, options: .atomic)
        return file
    }

    private func tick(_ seconds: Double) {
        if seconds.isFinite, !(player.currentItem == nil) {
            if seconds > lastSec, seconds - lastSec < 2 { listened += seconds - lastSec }
            lastSec = seconds
            elapsed = seconds
            if !segments.isEmpty, let hit = segments.first(where: { seconds >= $0[0] && seconds < $0[1] - 0.6 }) { seekTo(seconds: hit[1]) }
        }
        // iOS sometimes reads these audio files as twice as long (and plays silence after the real end), so when the
        // player's length is far above what YouTube says, trust YouTube, and end the song at the real end.
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 {
            let doubled = expected > 0 && d > expected * 1.5
            duration = doubled ? expected : d
            if doubled && seconds >= expected - 0.3 { songEnded() }
        } else if expected > 0 {
            duration = expected
        }
        if downloadMode, duration > 0, elapsed / duration > 0.2 { prefetchNext() }
        updateNowPlaying(force: false)
    }

    /// Download-first only: fetch the next song while this one plays, so there is no wait between songs.
    private func prefetchNext() {
        guard queue.indices.contains(index + 1) else { return }
        let n = queue[index + 1]
        guard n.id.count >= 11, downloads.url(for: n.id) == nil, prefetch?.id != n.id else { return }
        let q = quality
        let eng = engine
        prefetch = (n.id, Task { [weak self] () -> (file: URL, info: StreamInfo)? in
            guard let self = self,
                  let info = try? await eng.stream(n.id, quality: q),
                  let file = try? await self.download(info, n, quiet: true) else { return nil }
            return (file, info)
        })
    }

    // MARK: speed, sleep timer, SponsorBlock

    func setSpeed(_ s: Float) {
        speed = s
        player.defaultRate = s
        if player.timeControlStatus != .paused { player.rate = s }
    }

    /// minutes: nil turns it off, 0 means "at the end of this song".
    func setSleep(minutes: Int?) {
        sleepTask?.cancel()
        sleepAtEnd = false
        sleepLabel = nil
        guard let m = minutes else { return }
        if m == 0 { sleepAtEnd = true; sleepLabel = "End of song"; return }
        sleepLabel = "\(m) min"
        sleepTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(m) * 60_000_000_000)
            if Task.isCancelled { return }
            player.pause()
            sleepLabel = nil
            flash("Sleep timer: paused")
        }
    }

    private func songEnded() {
        if endedHandled { return }
        endedHandled = true
        if sleepAtEnd { sleepAtEnd = false; sleepLabel = nil; flash("Sleep timer: paused"); return }
        if repeatMode == 2 {                                                    // repeat one: the same song again
            endedHandled = false
            lastSec = 0
            seekTo(seconds: 0)
            player.play()
            return
        }
        next()
    }

    private struct SBItem: Decodable { let segment: [Double] }
    /// Non-music parts of a music video (intros, outros, talking), from SponsorBlock. Songs it has no data for play normally.
    private func loadSegments(_ t: Track) async {
        guard t.id.count >= 11 else { return }
        let cats = "%5B%22music_offtopic%22,%22intro%22,%22outro%22,%22selfpromo%22,%22sponsor%22,%22interaction%22%5D"
        guard let url = URL(string: "https://sponsor.ajay.app/api/skipSegments?videoID=\(t.id)&categories=\(cats)&actionTypes=%5B%22skip%22%5D"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONDecoder().decode([SBItem].self, from: data) else { return }
        if current.id == t.id { segments = items.map { $0.segment }.filter { $0.count == 2 } }
    }

    // MARK: queue, radio, lyrics, stats

    /// Counts a play for Analytics once a song has been left (finished, skipped, or replaced).
    private func flushListen() {
        if let t = playingTrack {
            if listened >= 5 { lib.recordPlay(t, seconds: listened) }
            if listened >= 2 {
                let skipped = listened / max(1, duration) < 0.3
                recentSignals.append((primaryArtist(t), skipped))
                if recentSignals.count > 20 { recentSignals.removeFirst(recentSignals.count - 20) }
                if skipped && dynamicQueue { pruneAfterSkip(t) }
            }
        }
        playingTrack = nil
        listened = 0
    }

    private func primaryArtist(_ t: Track) -> String { (t.artist.components(separatedBy: ", ").first ?? "").lowercased() }

    /// Skipped an artist twice recently? Stop lining up more of them in the next few slots.
    private func pruneAfterSkip(_ t: Track) {
        let a = primaryArtist(t)
        guard !a.isEmpty, recentSignals.filter({ $0.skipped && $0.artist == a }).count >= 2 else { return }
        var i = min(queue.count, index + 9) - 1
        while i > index {
            if queue.indices.contains(i), primaryArtist(queue[i]) == a { queue.remove(at: i) }
            i -= 1
        }
    }

    // MARK: lock screen artwork

    /// The cover for the lock screen and Control Center.
    private func loadNowArtwork(_ t: Track) async {
        guard let u = sizedURL(t.thumbnail?.absoluteString, 544) ?? t.thumbnail else { return }
        guard let img = await ImageCache.shared.load(u) else { return }
        guard current.id == t.id else { return }
        nowArtwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        nowArtworkFor = t.id
        updateNowPlaying(force: true)
    }

    // MARK: accent from the artwork

    func refreshArtAccent() { Task { await updateArtAccent(current) } }

    private func updateArtAccent(_ t: Track) async {
        guard UserDefaults.standard.string(forKey: "accent") == "art",
              let u = sizedURL(t.thumbnail?.absoluteString, 60),
              let (d, _) = try? await URLSession.shared.data(from: u),
              let cg = UIImage(data: d)?.cgImage,
              let c = Self.vivid(cg) else { return }
        artAccent = c
    }

    /// The most vivid colour in a picture.
    private static func vivid(_ cg: CGImage) -> Color? {
        let w = 24, h = 24
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var best = (score: -1.0, r: 0.0, g: 0.0, b: 0.0)
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            let score = (mx == 0 ? 0 : (mx - mn) / mx) * mx
            if mx > 0.35, score > best.score { best = (score, r, g, b) }
        }
        return best.score < 0.15 ? nil : Color(red: best.r, green: best.g, blue: best.b)
    }

    /// Near the end of the queue, ask the engine for songs like the current one and add them (once per song).
    private func extendQueueIfNeeded(_ t: Track) { Task { await topUp() } }

    /// Keeps the queue going: when three or fewer songs are left (or `force`), adds songs like the last one. Unless `plain`, a couple of
    /// songs you like are used as extra seeds too, so the mix drifts toward your taste. Songs marked "not interested" are left out.
    private func topUp(force: Bool = false, plain: Bool = false) async {
        guard !extending, autoplay, let last = queue.last, last.id.count >= 11 else { return }
        if !force && queue.count - index > 3 { return }
        extending = true
        defer { extending = false }
        var seeds = [last]
        if dynamicQueue && !plain {
            let pool = (Array(lib.likes.prefix(30)) + Array(lib.history.prefix(10))).filter { $0.id.count >= 11 && $0.id != last.id }
            seeds += Array(pool.shuffled().prefix(2))
        }
        let eng = engine
        let lists = await withTaskGroup(of: (Int, [Track]).self) { group -> [[Track]] in
            for (i, s) in seeds.enumerated() { group.addTask { (i, (try? await eng.radio(s.id)) ?? []) } }
            var out = [[Track]](repeating: [], count: seeds.count)
            for await (i, l) in group { out[i] = l }
            return out
        }
        var cands: [(track: Track, score: Double)] = []
        for (li, l) in lists.enumerated() {
            for (i, t) in l.enumerated() { cands.append((t, 1 - Double(i) / Double(max(1, l.count)) + (li == 0 ? 0.15 : 0))) }
        }
        cands.sort { $0.score > $1.score }
        var seen = Set(queue.map { $0.id })
        var more: [Track] = []
        for c in cands where !seen.contains(c.track.id) && !lib.isDisliked(c.track) {
            seen.insert(c.track.id)
            more.append(c.track)
            if more.count >= 25 { break }
        }
        if !more.isEmpty { queue.append(contentsOf: more) }
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        start()
    }
    func removeFromQueue(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        queue.remove(at: i)
        if i < index { index -= 1 }
    }
    func seekTo(seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        elapsed = seconds
    }

    func loadLyrics() async {
        let t = current
        if lyricsFor == t.id { return }
        lyricsFor = t.id
        lyricsState = .loading
        do {
            let l = try await engine.lyrics(for: t)
            if lyricsFor == t.id { lyricsState = (l.lines?.isEmpty == false || (l.lyrics ?? "").isEmpty == false) ? .ready(l) : .none }
        } catch {
            if lyricsFor == t.id { lyricsState = .none }
        }
    }

    // MARK: lock screen and headphones

    private func updateNowPlaying(force: Bool) {
        let now = Date().timeIntervalSince1970
        if !force && now - lastInfoUpdate < 1 { return }
        lastInfoUpdate = now
        let t = current
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : Double(t.seconds),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let a = nowArtwork, nowArtworkFor == t.id { info[MPMediaItemPropertyArtwork] = a }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggleIfPaused(true) }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggleIfPaused(false) }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                let pos = e.positionTime
                Task { @MainActor in
                    guard let self = self else { return }
                    let d = self.duration > 0 ? self.duration : Double(self.current.seconds)
                    self.seek(pos / d)
                }
            }
            return .success
        }
    }
    private func toggleIfPaused(_ wantPlaying: Bool) {
        if wantPlaying && player.timeControlStatus == .paused { toggle() }
        if !wantPlaying && player.timeControlStatus != .paused { toggle() }
    }
}

func clock(_ s: Double) -> String {
    let n = max(0, Int(s))
    return String(format: "%d:%02d", n / 60, n % 60)
}
