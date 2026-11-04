// ---------------------------------------------------------------------------------------------------------------
// Signer (stage 1 of in-app updates): keeps your signing certificate (.p12) and provisioning profile on the phone and
// checks them. Nothing here leaves the device.
//   - the .p12 and the .mobileprovision live in Application Support/Signing, excluded from backups
//   - the .p12 password lives in the Keychain
//   - the app's own embedded.mobileprovision (the profile it was installed with) is used to check the new files fit this phone
// It is appended to AppDelegate.swift by scripts/patch_ios.py and registered through capacitor.config.json.
// ---------------------------------------------------------------------------------------------------------------

private struct SignDER {
    let d: [UInt8]
    var i = 0
    init(_ data: Data) { d = [UInt8](data) }

    /// The element header at `i`: its tag and where its content starts and ends. Does not move `i`.
    func header() -> (tag: UInt8, start: Int, end: Int)? {
        guard i + 2 <= d.count else { return nil }
        let tag = d[i]
        var len = Int(d[i + 1])
        var p = i + 2
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n > 0, n <= 4, p + n <= d.count else { return nil }
            len = 0
            for k in 0..<n { len = (len << 8) | Int(d[p + k]) }
            p += n
        }
        guard p + len <= d.count else { return nil }
        return (tag, p, p + len)
    }
}

/// The end of a certificate's validity (notAfter), read straight from its DER bytes.
private func signCertNotAfter(_ cert: Data) -> Date? {
    var r = SignDER(cert)
    guard let outer = r.header(), outer.tag == 0x30 else { return nil }
    r.i = outer.start
    guard let tbs = r.header(), tbs.tag == 0x30 else { return nil }
    r.i = tbs.start
    guard var e = r.header() else { return nil }
    if e.tag == 0xA0 {                                   // optional [0] version, then the serial number
        r.i = e.end
        guard let n = r.header() else { return nil }
        e = n
    }
    r.i = e.end
    guard let sigAlg = r.header() else { return nil }
    r.i = sigAlg.end
    guard let issuer = r.header() else { return nil }
    r.i = issuer.end
    guard let validity = r.header(), validity.tag == 0x30 else { return nil }
    r.i = validity.start
    guard let nb = r.header() else { return nil }
    r.i = nb.end
    guard let na = r.header() else { return nil }
    let text = String(decoding: r.d[na.start..<na.end], as: UTF8.self)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = na.tag == 0x18 ? "yyyyMMddHHmmss'Z'" : "yyMMddHHmmss'Z'"
    return f.date(from: text)
}

private struct SignProfile {
    let name: String
    let team: String
    let appId: String
    let expires: Date?
    let devices: [String]
    let allDevices: Bool
    let certs: [Data]
}

/// A .mobileprovision is a signed blob with an XML plist inside; the plist is all we need.
private func signParseProfile(_ data: Data) -> SignProfile? {
    guard let a = data.range(of: Data("<?xml".utf8)), let b = data.range(of: Data("</plist>".utf8)), a.lowerBound < b.upperBound else { return nil }
    let xml = data.subdata(in: a.lowerBound..<b.upperBound)
    guard let p = (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any] else { return nil }
    let ent = p["Entitlements"] as? [String: Any] ?? [:]
    return SignProfile(
        name: p["Name"] as? String ?? "",
        team: (p["TeamIdentifier"] as? [String])?.first ?? "",
        appId: ent["application-identifier"] as? String ?? "",
        expires: p["ExpirationDate"] as? Date,
        devices: p["ProvisionedDevices"] as? [String] ?? [],
        allDevices: p["ProvisionsAllDevices"] as? Bool ?? false,
        certs: p["DeveloperCertificates"] as? [Data] ?? [])
}

/// Does a profile's app id ("TEAM.com.x.app", "TEAM.com.x.*" or "TEAM.*") cover this bundle id?
private func signBundleMatches(_ profile: SignProfile, _ bundle: String) -> Bool {
    let pattern = profile.appId.hasPrefix(profile.team + ".") ? String(profile.appId.dropFirst(profile.team.count + 1)) : profile.appId
    if pattern == "*" { return true }
    if pattern.hasSuffix("*") { return bundle.hasPrefix(String(pattern.dropLast())) }
    return pattern == bundle
}

private enum SignVault {
    static let service = "com.ytmusic.signing"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func set(_ account: String, _ value: String) {
        SecItemDelete(base(account) as CFDictionary)
        var add = base(account)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func remove(_ account: String) { SecItemDelete(base(account) as CFDictionary) }
}

@objc(SignerPlugin)
public class SignerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SignerPlugin"
    public let jsName = "Signer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "importCertificate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "importProfile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "remove", returnType: CAPPluginReturnPromise),
    ]

    private func dir() throws -> URL {
        var u = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Signing", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try u.setResourceValues(rv)
        return u
    }

    private func save(_ data: Data, as name: String) throws {
        try data.write(to: try dir().appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }

    private func installedProfile() -> SignProfile? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let d = FileManager.default.contents(atPath: path) else { return nil }
        return signParseProfile(d)
    }

    /// Everything the app screen needs: what is saved, and whether it fits this phone and this app.
    private func snapshot() -> [String: Any] {
        var out: [String: Any] = [:]
        let now = Date()
        var certDer: Data?
        if let d = try? dir(),
           let raw = try? Data(contentsOf: d.appendingPathComponent("cert.json")),
           let j = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let name = j["name"] as? String, let exp = j["expires"] as? Int, let b64 = j["der"] as? String, let der = Data(base64Encoded: b64) {
            certDer = der
            out["cert"] = ["name": name, "expires": exp] as [String: Any]
        }
        var profile: SignProfile?
        if let d = try? dir(), let raw = try? Data(contentsOf: d.appendingPathComponent("profile.mobileprovision")) { profile = signParseProfile(raw) }
        if let p = profile {
            var info: [String: Any] = ["name": p.name, "team": p.team, "appId": p.appId, "devices": p.devices.count, "allDevices": p.allDevices]
            if let e = p.expires { info["expires"] = ms(e) }
            out["profile"] = info
        }
        let installed = installedProfile()
        let bundle = Bundle.main.bundleIdentifier ?? ""
        out["bundleId"] = bundle
        if let i = installed {
            var inst: [String: Any] = ["name": i.name, "team": i.team]
            if let e = i.expires { inst["expires"] = ms(e) }
            out["installed"] = inst
        }
        var checks: [String: Any] = [:]
        if let c = certDer, let e = signCertNotAfter(c) { checks["certValid"] = e > now }
        if let p = profile {
            checks["profileValid"] = (p.expires ?? Date.distantPast) > now
            checks["bundleMatch"] = signBundleMatches(p, bundle)
            if let c = certDer { checks["certInProfile"] = p.certs.contains(c) }
            if let i = installed {
                checks["sameTeam"] = i.team == p.team
                if !i.devices.isEmpty { checks["deviceIncluded"] = p.allDevices || Set(i.devices).isSubset(of: Set(p.devices)) }
                else if i.allDevices { checks["deviceIncluded"] = p.allDevices }
                if let c = certDer { checks["certIsInstalledOne"] = i.certs.contains(c) }
            }
        }
        out["checks"] = checks
        return out
    }

    @objc func status(_ call: CAPPluginCall) { call.resolve(snapshot()) }

    /// { data (base64 of the .p12), password }
    @objc func importCertificate(_ call: CAPPluginCall) {
        guard let b64 = call.getString("data"), let data = Data(base64Encoded: b64), let password = call.getString("password") else {
            call.reject("Missing the certificate file or its password"); return
        }
        var items: CFArray?
        let st = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        if st == errSecAuthFailed { call.reject("Wrong password for that certificate file"); return }
        guard st == errSecSuccess, let arr = items as? [[String: Any]], let first = arr.first, let idRef = first[kSecImportItemIdentity as String] else {
            call.reject("That doesn't look like a valid .p12 file (code \(st))"); return
        }
        let identity = idRef as! SecIdentity
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef else {
            call.reject("Couldn't read the certificate inside that file"); return
        }
        let der = SecCertificateCopyData(cert) as Data
        let name = (SecCertificateCopySubjectSummary(cert) as String?) ?? "Certificate"
        guard let expires = signCertNotAfter(der) else { call.reject("Couldn't read the certificate's expiry date"); return }
        do {
            try save(data, as: "cert.p12")
            let meta: [String: Any] = ["name": name, "expires": ms(expires), "der": der.base64EncodedString()]
            try save(try JSONSerialization.data(withJSONObject: meta), as: "cert.json")
        } catch { call.reject("Couldn't save the certificate: \(error.localizedDescription)"); return }
        SignVault.set("p12", password)
        call.resolve(snapshot())
    }

    /// { data (base64 of the .mobileprovision) }
    @objc func importProfile(_ call: CAPPluginCall) {
        guard let b64 = call.getString("data"), let data = Data(base64Encoded: b64) else { call.reject("Missing the profile file"); return }
        guard signParseProfile(data) != nil else { call.reject("That doesn't look like a .mobileprovision file"); return }
        do { try save(data, as: "profile.mobileprovision") } catch { call.reject("Couldn't save the profile: \(error.localizedDescription)"); return }
        call.resolve(snapshot())
    }

    /// Forgets the certificate, the profile and the password.
    @objc func remove(_ call: CAPPluginCall) {
        if let d = try? dir() { for n in ["cert.p12", "cert.json", "profile.mobileprovision"] { try? FileManager.default.removeItem(at: d.appendingPathComponent(n)) } }
        SignVault.remove("p12")
        call.resolve(snapshot())
    }
}
