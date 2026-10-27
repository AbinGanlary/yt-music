// ---------------------------------------------------------------------------------------------------------------
// Ipv4Http: a tiny HTTPS client used by the on-device YouTube engine.
//   - always IPv4 (iOS otherwise picks IPv4 or IPv6 per connection, and YouTube treats the two very differently)
//   - a brand-new connection for every request, no cookies, no cache, no HTTP/2 reuse
// It is appended to AppDelegate.swift by scripts/patch_ios.py and registered through capacitor.config.json.
// ---------------------------------------------------------------------------------------------------------------

private enum V4Error: LocalizedError {
    case badURL, timeout, truncated

    var errorDescription: String? {
        switch self {
        case .badURL: return "bad URL"
        case .timeout: return "timed out"
        case .truncated: return "connection closed early"
        }
    }
}

private struct V4Response {
    let status: Int
    let headers: [String: String]
    let body: Data
}

private final class V4Request: @unchecked Sendable {
    private let url: URL
    private let method: String
    private let headers: [String: String]
    private let body: Data?
    private let queue = DispatchQueue(label: "ipv4http.request")
    private var conn: NWConnection?
    private var buffer = Data()
    private var finished = false
    private var completion: ((Result<V4Response, Error>) -> Void)?

    init(url: URL, method: String, headers: [String: String], body: Data?) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    func start(timeout: TimeInterval, completion: @escaping (Result<V4Response, Error>) -> Void) {
        self.completion = completion
        queue.async { [self] in
            guard let host = url.host, url.scheme == "https" else { finish(.failure(V4Error.badURL)); return }
            let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) ?? NWEndpoint.Port.https
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
            conn = c
            c.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: send()
                case .failed(let e): finish(.failure(e))
                case .waiting(let e): finish(.failure(e))       // no IPv4 route: fail fast so the caller can fall back
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(.failure(V4Error.timeout)) }
        }
    }

    private func send() {
        var path = "/"
        if let comp = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            path = comp.percentEncodedPath.isEmpty ? "/" : comp.percentEncodedPath
            if let q = comp.percentEncodedQuery { path += "?" + q }
        }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(url.host ?? "")\r\n"
        let skip: Set<String> = ["host", "content-length", "connection", "accept-encoding", "transfer-encoding"]
        for (k, v) in headers where !skip.contains(k.lowercased()) { head += "\(k): \(v)\r\n" }
        head += "Accept-Encoding: identity\r\nConnection: close\r\n"
        if body != nil || method == "POST" { head += "Content-Length: \(body?.count ?? 0)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if let b = body { out.append(b) }
        conn?.send(content: out, completion: .contentProcessed { [self] error in
            if let error = error { finish(.failure(error)) } else { receive() }
        })
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [self] data, _, isComplete, error in
            if finished { return }
            if let data = data, !data.isEmpty { buffer.append(data) }
            let closed = isComplete || error != nil
            if let r = parse(closed: closed) { finish(.success(r)); return }
            if closed { finish(.failure(error ?? V4Error.truncated)); return }
            receive()
        }
    }

    /// A finished response, or nil while more bytes are still needed.
    private func parse(closed: Bool) -> V4Response? {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = buffer.range(of: sep) else { return nil }
        let headText = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var hdrs: [String: String] = [:]
        var lower: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            let k = String(l[l.startIndex..<i]).trimmingCharacters(in: .whitespaces)
            let v = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            hdrs[k] = v
            lower[k.lowercased()] = v
        }
        let rest = Data(buffer[r.upperBound...])
        if status == 204 || status == 304 || (100..<200).contains(status) || method == "HEAD" {
            return V4Response(status: status, headers: hdrs, body: Data())
        }
        if (lower["transfer-encoding"] ?? "").lowercased().contains("chunked") {
            guard let decoded = decodeChunked(rest) else { return nil }
            return V4Response(status: status, headers: hdrs, body: decoded)
        }
        if let cl = lower["content-length"], let n = Int(cl) {
            if rest.count >= n { return V4Response(status: status, headers: hdrs, body: Data(rest.prefix(n))) }
            return nil
        }
        return closed ? V4Response(status: status, headers: hdrs, body: rest) : nil
    }

    private func decodeChunked(_ d: Data) -> Data? {
        var out = Data()
        var i = d.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = d.range(of: crlf, options: [], in: i..<d.endIndex) else { return nil }
            let line = String(decoding: d[i..<lineEnd.lowerBound], as: UTF8.self)
            let sizeText = (line.split(separator: ";").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText, radix: 16) else { return nil }
            i = lineEnd.upperBound
            if size == 0 { return out }
            guard d.distance(from: i, to: d.endIndex) >= size + 2 else { return nil }
            out.append(d[i..<d.index(i, offsetBy: size)])
            i = d.index(i, offsetBy: size + 2)
        }
    }

    private func finish(_ result: Result<V4Response, Error>) {
        if finished { return }
        finished = true
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
        let cb = completion
        completion = nil
        cb?(result)
    }
}

@objc(Ipv4HttpPlugin)
public class Ipv4HttpPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "Ipv4HttpPlugin"
    public let jsName = "Ipv4Http"
    public let pluginMethods: [CAPPluginMethod] = [CAPPluginMethod(name: "request", returnType: CAPPluginReturnPromise)]

    /// { url, method, headers, body (text), binary (reply as base64) } -> { status, headers, data }
    @objc func request(_ call: CAPPluginCall) {
        guard let s = call.getString("url"), let url = URL(string: s) else { call.reject("bad url"); return }
        let method = (call.getString("method") ?? "GET").uppercased()
        var headers: [String: String] = [:]
        if let h = call.getObject("headers") { for (k, v) in h { if let sv = v as? String { headers[k] = sv } } }
        let body = call.getString("body").map { Data($0.utf8) }
        let binary = call.getBool("binary") ?? false
        let req = V4Request(url: url, method: method, headers: headers, body: body)
        req.start(timeout: 30) { result in
            _ = req                                              // keeps the request alive until it finishes
            switch result {
            case .success(let r):
                call.resolve([
                    "status": r.status,
                    "headers": r.headers,
                    "data": binary ? r.body.base64EncodedString() : String(decoding: r.body, as: UTF8.self),
                ])
            case .failure(let e):
                call.reject(e.localizedDescription)
            }
        }
    }
}
