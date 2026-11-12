import SwiftUI
import WebKit

struct StreamInfo: Decodable {
    let url: String
    let size: Int?
    let bitrate: Int?
    let itag: Int?
    let approxMs: Int?        // how long YouTube says the song is
}
struct RawTrack: Decodable {
    let videoId: String
    let title: String?
    let artists: [String]?
    let album: String?
    let video: Bool?
    let duration: String?
    let thumbnail: String?
}
struct RawSection: Decodable { let items: [RawTrack] }

struct SignInInfo: Decodable {
    let url: String
    let code: String
    let expiresIn: Int?
}
struct AccountInfo: Decodable {
    let signedIn: Bool?
    let name: String?
    let handle: String?
    let error: String?
}

/// One shelf of the signed-in account's own YouTube Music home: songs, or albums and playlists.
struct YTShelf: Decodable {
    let title: String
    let tracks: [RawTrack]
    let colls: [Coll]
    enum CodingKeys: String, CodingKey { case title, kind, items }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        let kind = try c.decode(String.self, forKey: .kind)
        if kind == "tracks" {
            tracks = try c.decode([RawTrack].self, forKey: .items)
            colls = []
        } else {
            colls = try c.decode([Coll].self, forKey: .items)
            tracks = []
        }
    }
}

/// Serves the bundled engine files on app://host/ and forwards the engine's network calls to the IPv4 client.
@MainActor
final class Bridge: NSObject, WKScriptMessageHandlerWithReply, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let root = Bundle.main.url(forResource: "Engine", withExtension: nil) else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        var rel = url.path
        if rel.isEmpty || rel == "/" { rel = "/host.html" }
        let file = root.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: file) else {
            if let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil) { urlSchemeTask.didReceive(r) }
            urlSchemeTask.didFinish(); return
        }
        let type = rel.hasSuffix(".js") ? "text/javascript; charset=utf-8" : rel.hasSuffix(".html") ? "text/html; charset=utf-8" : "application/octet-stream"
        let head = ["Content-Type": type, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"]
        if let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: head) { urlSchemeTask.didReceive(r) }
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let o = message.body as? [String: Any], let s = o["url"] as? String, let url = URL(string: s) else {
            replyHandler(nil, "bad request"); return
        }
        let method = ((o["method"] as? String) ?? "GET").uppercased()
        var headers: [String: String] = [:]
        if let h = o["headers"] as? [String: Any] { for (k, v) in h { if let sv = v as? String { headers[k] = sv } } }
        let body = (o["body"] as? String).map { Data($0.utf8) }
        let binary = (o["binary"] as? Bool) ?? false
        Task {
            do {
                let r = try await v4Request(url: url, method: method, headers: headers, body: body)
                let text = binary ? r.body.base64EncodedString() : String(decoding: r.body, as: UTF8.self)
                replyHandler(["status": r.status, "headers": r.headers, "data": text], nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }
}

/// The YouTube engine, running in a hidden web view.
@MainActor
final class EngineHost: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = EngineHost()
    @Published var status = "Engine: starting…"
    let webView: WKWebView
    private let bridge = Bridge()
    private var loaded = false
    private var loadError: Error?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    override init() {
        let cfg = WKWebViewConfiguration()
        let b = bridge
        cfg.setURLSchemeHandler(b, forURLScheme: "app")
        cfg.userContentController.addScriptMessageHandler(b, contentWorld: .page, name: "net")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        if let u = URL(string: "app://host/host.html") { webView.load(URLRequest(url: u)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ e: Error) {
        loadError = e
        status = "Engine: page failed to load (\(e.localizedDescription))"
        waiters.forEach { $0.resume(throwing: e) }
        waiters = []
    }
    private func waitLoaded() async throws {
        if loaded { return }
        if let e = loadError { throw e }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in waiters.append(c) }
    }

    private func call(_ body: String, _ args: [String: Any]) async throws -> Data {
        try await waitLoaded()
        do {
            let r = try await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
            guard let s = r as? String else { throw URLError(.cannotParseResponse) }
            status = "Engine: ready"
            return Data(s.utf8)
        } catch {
            let ns = error as NSError
            let msg = (ns.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
            status = "Engine error: " + String(msg.prefix(160))
            throw NSError(domain: "engine", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    /// The country that catalogue calls follow: none while "Global content" is on (the default).
    static func loc() -> String {
        let d = UserDefaults.standard
        if d.object(forKey: "global") == nil || d.bool(forKey: "global") { return "" }
        let c = d.string(forKey: "country") ?? "auto"
        return c == "auto" ? (Locale.current.region?.identifier ?? "") : c
    }
    /// Adds the chosen country to catalogue calls so charts, search and home match it (not lyrics).
    private func withLoc(_ path: String) -> String {
        let l = Self.loc()
        if l.isEmpty || path.hasPrefix("/api/lyrics") || path.contains("loc=") { return path }
        return path + (path.contains("?") ? "&" : "?") + "loc=" + l
    }

    /// Any engine endpoint, decoded into the type you ask for.
    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let data = try await call("return await window.host.api(p)", ["p": withLoc(path)])
        return try JSONDecoder().decode(T.self, from: data)
    }
    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }

    // MARK: Google account (device-code sign-in)
    func isSignedIn() async -> Bool {
        guard let d = try? await call("return await window.host.signedIn()", [:]) else { return false }
        return String(decoding: d, as: UTF8.self) == "true"
    }
    func beginSignIn() async throws -> SignInInfo {
        let d = try await call("return await window.host.signIn()", [:])
        return try JSONDecoder().decode(SignInInfo.self, from: d)
    }
    /// Waits (possibly minutes) until the code has been approved at google.com/device.
    func finishSignIn() async throws -> AccountInfo {
        let d = try await call("return await window.host.signInDone()", [:])
        return try JSONDecoder().decode(AccountInfo.self, from: d)
    }
    /// What the phone's network looks like to YouTube, as readable text (Settings → About → Connection check).
    func connectionReport() async throws -> String {
        let d = try await call("return await window.host.diagnose()", [:])
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "No answer" }
        var lines: [String] = []
        lines.append("IPv4 address: \(o["v4"] as? String ?? "none")")
        lines.append("IPv6 address: \(o["v6"] as? String ?? "none")")
        if let s = o["stream"] as? [String: Any] {
            if let e = s["error"] as? String { lines.append("Test stream failed: \(e)") }
            else { lines.append("Test stream: \(s["client"] as? String ?? "?") for \(s["ip"] as? String ?? "?"), audio check \(s["status"] as? Int ?? 0)") }
        }
        if let c = o["clients"] as? [String], !c.isEmpty { lines.append("Clients:"); lines.append(contentsOf: c.map { "  " + $0 }) }
        if let i = o["info"] as? [String: Any] { lines.append("Session: seen as \(i["remoteHost"] as? String ?? "?"), visitor \(i["visitor"] as? String ?? "?")") }
        lines.append("Own IPv4 client: \(o["v4client"] as? String ?? "?")")
        lines.append("Signed in: \((o["signedIn"] as? Bool) == true ? "yes" : "no")")
        return lines.joined(separator: "\n")
    }
    func resetConnection() async -> String {
        guard let d = try? await call("return await window.host.resetConnection()", [:]) else { return "Couldn't reset" }
        return "Connection reset (" + String(decoding: d, as: UTF8.self) + ")"
    }
    func countries() async -> [String] { (try? await get("/api/countries", as: [String].self)) ?? [] }

    func signOut() async { _ = try? await call("return await window.host.signOut()", [:]) }

    func radio(_ id: String) async throws -> [Track] {
        let raw: [RawTrack] = try await get("/api/radio/\(id)?limit=25")
        return raw.compactMap { Track($0) }
    }
    func lyrics(for t: Track) async throws -> Lyrics {
        try await get("/api/lyrics/\(t.id)?title=\(Self.enc(t.title))&artist=\(Self.enc(t.artist))&dur=\(t.seconds)")
    }

    func search(_ q: String) async throws -> [Track] {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let data = try await call("return await window.host.api(p)", ["p": withLoc("/api/search?q=\(enc)&filter=songs&limit=20")])
        return try JSONDecoder().decode([RawTrack].self, from: data).compactMap { Track($0) }
    }

    func quickPicks() async throws -> [Track] {
        let data = try await call("return await window.host.api(p)", ["p": withLoc("/api/home")])
        let secs = try JSONDecoder().decode([RawSection].self, from: data)
        var seen = Set<String>()
        var out: [Track] = []
        for r in secs.flatMap({ $0.items }) where !seen.contains(r.videoId) {
            seen.insert(r.videoId)
            if let t = Track(r) { out.append(t) }
            if out.count >= 14 { break }
        }
        return out
    }

    func stream(_ id: String, fresh: Int = 0, quality: String = "high") async throws -> StreamInfo {
        let data = try await call("return await window.host.stream(id, fresh, q)", ["id": id, "fresh": fresh, "q": quality])
        return try JSONDecoder().decode(StreamInfo.self, from: data)
    }
}

/// Puts the hidden web view in the view tree (a web view that is not on screen can have its timers paused).
struct EngineView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { EngineHost.shared.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
