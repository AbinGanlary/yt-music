import SwiftUI

/// Your music taste: languages and artists. Home's "Picked for you" shelf is built from it.
enum Taste {
    static let languages = [
        "Hindi", "English", "Punjabi", "Tamil", "Telugu", "Malayalam", "Kannada", "Bengali", "Marathi",
        "Gujarati", "Bhojpuri", "Haryanvi", "Urdu", "Korean", "Japanese", "Spanish", "Portuguese", "French", "Arabic",
    ]
    static func langs(_ stored: String) -> [String] { stored.split(separator: ",").map(String.init) }
    static func artists(_ stored: String) -> [(id: String, name: String)] {
        stored.split(separator: "|").compactMap { part in
            let p = part.components(separatedBy: "::")
            return p.count == 2 ? (p[0], p[1]) : nil
        }
    }
    static func store(_ a: [(id: String, name: String)]) -> String { a.map { "\($0.id)::\($0.name)" }.joined(separator: "|") }
}

struct TasteSheet: View {
    @EnvironmentObject var engine: EngineHost
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tasteLangs") private var langStore = ""
    @AppStorage("tasteArtists") private var artistStore = ""
    @State private var query = ""
    @State private var found: [Coll] = []

    private var langs: [String] { Taste.langs(langStore) }
    private var artists: [(id: String, name: String)] { Taste.artists(artistStore) }

    private func toggle(_ l: String) {
        var cur = langs
        if let i = cur.firstIndex(of: l) { cur.remove(at: i) } else { cur.append(l) }
        langStore = cur.joined(separator: ",")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(Taste.languages, id: \.self) { l in
                            Button { tap(); toggle(l) } label: {
                                Text(l).font(.footnote.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .background(langs.contains(l) ? Theme.accent : Theme.surface, in: Capsule())
                                    .foregroundStyle(langs.contains(l) ? Color.black : Color.primary)
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(langs.contains(l) ? 0 : 0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Music languages")
                }

                Section {
                    ForEach(artists, id: \.id) { a in
                        HStack {
                            Text(a.name)
                            Spacer()
                            Button { artistStore = Taste.store(artists.filter { $0.id != a.id }) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                                .buttonStyle(.plain)
                        }
                    }
                    TextField("Search for an artist", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await search() } }
                    ForEach(found) { c in
                        Button {
                            if artists.count < 12, !artists.contains(where: { $0.id == c.id }) { artistStore = Taste.store(artists + [(c.id, c.title)]) }
                            found = []
                            query = ""
                        } label: {
                            HStack { Text(c.title); Spacer(); Image(systemName: "plus.circle") }
                        }
                    }
                } header: {
                    Text("Artists you like")
                } footer: {
                    Text("Pick your languages and a few artists, and Home gets a “Picked for you” shelf.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Your music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        found = (try? await engine.get("/api/artists/search?q=\(EngineHost.enc(q))", as: [Coll].self)) ?? []
    }
}

/// Settings → For you → Location: follow the phone's region or pick a country.
struct CountryPicker: View {
    @EnvironmentObject var engine: EngineHost
    @AppStorage("country") private var country = "auto"
    @State private var codes: [String] = []
    @State private var query = ""

    private func name(_ code: String) -> String { Locale.current.localizedString(forRegionCode: code) ?? code }

    var body: some View {
        List {
            Button { country = "auto" } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Auto")
                        Text("Uses your phone's region, not GPS").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if country == "auto" { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                }
            }
            ForEach(codes.filter { query.isEmpty || name($0).localizedCaseInsensitiveContains(query) }, id: \.self) { c in
                Button { country = c } label: {
                    HStack {
                        Text(name(c))
                        Spacer()
                        if country == c { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                }
            }
        }
        .foregroundStyle(Color.primary)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .searchable(text: $query, prompt: "Search countries")
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let all = await engine.countries()
            codes = all.sorted { name($0) < name($1) }
        }
    }
}

/// The result of Settings → About → Connection check.
struct ReportSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .textSelection(.enabled)
            }
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Copy") { UIPasteboard.general.string = text } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
