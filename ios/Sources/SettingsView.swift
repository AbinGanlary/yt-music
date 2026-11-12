import SwiftUI

/// "2.0.0 (12)": the version and build number of this app.
private var appVersion: String {
    let i = Bundle.main.infoDictionary
    return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
}

struct SettingsView: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var engine: EngineHost
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var theme = 0
    @AppStorage("accent") private var accentHex = "#ff6a3d"          // a colour, or "art" to follow the cover
    @AppStorage("sponsorBlock") private var sponsorBlock = false
    @AppStorage("dynamic") private var dynamicQueue = true
    @AppStorage("quality") private var quality = "high"
    @AppStorage("dlQuality") private var dlQuality = "high"
    @AppStorage("smartDl") private var smartDl = false
    @AppStorage("playbackMode") private var playbackMode = "auto"
    @AppStorage("global") private var global = true
    @AppStorage("country") private var country = "auto"
    @AppStorage("tasteLangs") private var tasteLangs = ""
    @AppStorage("tasteArtists") private var tasteArtists = ""
    @AppStorage("homeHide") private var hidden = ""
    @AppStorage("ytSignedIn") private var signedIn = false
    @AppStorage("ytName") private var accountName = ""
    @State private var showSignIn = false
    @State private var showTaste = false
    @State private var report: (title: String, text: String)?
    @State private var checking = false

    private let homeSections: [(id: String, label: String)] = [
        ("moods", "Mood chips"), ("listen", "Listen again"), ("mix", "Picked for you"), ("because", "Because you played"), ("quick", "Quick picks"), ("trend", "Trending"),
    ]

    private func homeBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !hidden.split(separator: ",").contains(Substring(id)) },
            set: { show in
                var set = Set(hidden.split(separator: ",").map(String.init))
                if show { set.remove(id) } else { set.insert(id) }
                hidden = set.sorted().joined(separator: ",")
            }
        )
    }

    private var customAccent: Binding<Color> {
        Binding(get: { Color(hex: accentHex) }, set: { accentHex = $0.hexString })
    }

    private var tasteSummary: String {
        let l = Taste.langs(tasteLangs).count, a = Taste.artists(tasteArtists).count
        if l == 0 && a == 0 { return "Choose" }
        return [l > 0 ? "\(l) language\(l > 1 ? "s" : "")" : nil, a > 0 ? "\(a) artist\(a > 1 ? "s" : "")" : nil].compactMap { $0 }.joined(separator: " · ")
    }
    private var locationSummary: String {
        country == "auto" ? "Auto" : (Locale.current.localizedString(forRegionCode: country) ?? country)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Keep playing similar songs", isOn: $player.autoplay)
                    Toggle("Dynamic queue", isOn: $dynamicQueue)
                    Toggle("Skip non-music parts", isOn: $sponsorBlock)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Similar songs are added when your queue is about to end. Dynamic queue stops lining up an artist you keep skipping. Skipping uses SponsorBlock to jump over intros, outros and talking in music videos.")
                }

                Section {
                    Picker("Audio quality", selection: $quality) {
                        Text("High").tag("high")
                        Text("Data saver").tag("low")
                    }
                    Picker("How songs start", selection: $playbackMode) {
                        Text("Auto").tag("auto")
                        Text("Stream").tag("stream")
                        Text("Download first").tag("download")
                    }
                } header: {
                    Text("Sound")
                } footer: {
                    Text("High is about 4 MB a song, Data saver about 1.6 MB. Auto streams and switches to downloading first if your phone is refused a stream. Stream never downloads. Download first waits for the whole song.")
                }

                Section {
                    Picker("Download quality", selection: $dlQuality) {
                        Text("High").tag("high")
                        Text("Data saver").tag("low")
                    }
                    Toggle("Smart downloads", isOn: $smartDl)
                    LabeledContent("Saved songs", value: "\(player.downloads.tracks.count)")
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Smart downloads saves a song for offline listening as soon as you like it. Download quality applies to new downloads and to Save to Files; songs already saved keep their quality.")
                }

                Section {
                    Button { showTaste = true } label: { LabeledContent("Improve your recommendations", value: tasteSummary) }
                        .foregroundStyle(Color.primary)
                    Toggle("Global content", isOn: $global)
                    NavigationLink { CountryPicker() } label: { LabeledContent("Location", value: locationSummary) }
                } header: {
                    Text("For you")
                } footer: {
                    Text("Home, Quick picks, New releases, Trending and Charts show music from around the world. Turn Global content off to follow your location instead. Location uses your phone's region, not GPS.")
                }

                Section {
                    if signedIn {
                        LabeledContent("YouTube account", value: accountName.isEmpty ? "Signed in" : accountName)
                        Button("Sign out", role: .destructive) {
                            Task { await engine.signOut(); signedIn = false; accountName = ""; player.notify("Signed out") }
                        }
                    } else {
                        Button("Sign in with Google") { showSignIn = true }
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Optional. Shows your YouTube Music home and liked songs, and gives the app another way in when YouTube refuses to play for anonymous apps. " + SignInSheet.risk)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $theme) {
                        Text("Dark").tag(0)
                        Text("Light").tag(1)
                        Text("Auto").tag(2)
                    }
                    .pickerStyle(.segmented)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                        ForEach(accentChoices, id: \.hex) { c in
                            Button { accentHex = c.hex; tap() } label: {
                                Circle().fill(Color(hex: c.hex)).frame(width: 36, height: 36)
                                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: accentHex == c.hex ? 3 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.name)
                        }
                        Button { accentHex = "art"; tap(); player.refreshArtAccent() } label: {
                            Circle()
                                .fill(AngularGradient(colors: [Color(hex: "#ff6a3d"), Color(hex: "#f5c542"), Color(hex: "#2dd4a7"), Color(hex: "#7c8cff"), Color(hex: "#ff6a3d")], center: .center))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().strokeBorder(Color.primary, lineWidth: accentHex == "art" ? 3 : 0).padding(-4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Follow the artwork")
                    }
                    .padding(.vertical, 6)
                    ColorPicker("Custom accent colour", selection: customAccent, supportsOpacity: false)
                }

                Section {
                    ForEach(homeSections, id: \.id) { s in
                        Toggle(s.label, isOn: homeBinding(s.id))
                    }
                } header: {
                    Text("Home sections")
                } footer: {
                    Text("Choose what shows on Home. Hidden sections are not loaded.")
                }

                Section("Your data") {
                    Button("Clear listening history") { player.lib.clearHistory(); player.notify("History cleared") }
                    Button("Clear listening stats", role: .destructive) { player.lib.clearPlays(); player.notify("Stats cleared") }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    Button {
                        checking = true
                        Task {
                            let text = (try? await engine.connectionReport()) ?? "The check didn't finish. Is the phone online?"
                            report = ("Connection check", text)
                            checking = false
                        }
                    } label: { LabeledContent("Connection check", value: checking ? "Running…" : "Run") }
                        .foregroundStyle(Color.primary)
                    Button {
                        Task { report = ("Reset connection", await engine.resetConnection()) }
                    } label: { LabeledContent("Reset connection", value: "Reset") }
                        .foregroundStyle(Color.primary)
                } header: {
                    Text("About")
                } footer: {
                    Text("Connection check shows your phone's network addresses and whether YouTube accepts a test stream; handy if songs don't start. Reset clears saved cookies and starts a fresh YouTube session. Songs are found and streamed with the same YouTube engine as the web app, running inside this app. Everything you save stays on this phone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showSignIn) { SignInSheet().environmentObject(engine) }
            .sheet(isPresented: $showTaste) { TasteSheet().environmentObject(engine) }
            .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
                ReportSheet(title: report?.title ?? "", text: report?.text ?? "")
            }
        }
    }
}
