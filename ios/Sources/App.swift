import SwiftUI

@main
struct YTMusicApp: App {
    @StateObject private var player = PlayerModel()

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)      // covers stay cached between launches
    }
    @StateObject private var engine = EngineHost.shared
    @AppStorage("theme") private var theme = 0              // 0 dark, 1 light, 2 follow the phone
    @AppStorage("accent") private var accentHex = "#ff6a3d"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(player.time)
                .environmentObject(engine)
                .background(EngineView().frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false))
                .preferredColorScheme(theme == 0 ? .dark : theme == 1 ? .light : nil)
                .tint(accentHex == "art" ? (player.artAccent ?? Color(hex: "#ff6a3d")) : Color(hex: accentHex))
        }
    }
}

struct RootView: View {
    @EnvironmentObject var player: PlayerModel
    @State private var showNow = false
    @State private var newName = ""
    @State private var renameText = ""

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            MixView()
                .tabItem { Label("Mix", systemImage: "dot.radiowaves.left.and.right") }
            ExploreView()
                .tabItem { Label("Explore", systemImage: "safari") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            AnalyticsView()
                .tabItem { Label("Analytics", systemImage: "chart.bar.fill") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayer(open: { showNow = true })
                .padding(.horizontal, 10)
                .padding(.bottom, 52)                       // sits just above the tab bar
        }
        .overlay(alignment: .top) { Toast() }
        .alert("New playlist", isPresented: $player.naming) {
            TextField("Name", text: $newName)
            Button("Create") { player.createPlaylist(named: newName); newName = "" }
            Button("Cancel", role: .cancel) { player.cancelPlaylist(); newName = "" }
        }
        .alert("Rename playlist", isPresented: Binding(get: { player.renaming != nil }, set: { if !$0 { player.renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let id = player.renaming { player.lib.rename(id, to: renameText) }; player.renaming = nil }
            Button("Cancel", role: .cancel) { player.renaming = nil }
        }
        .onChange(of: player.renaming) { id in
            if let id = id { renameText = player.lib.playlist(id)?.name ?? "" }
        }
        .animation(.easeOut(duration: 0.25), value: player.message)
        .sheet(item: $player.shareItem) { item in ShareSheet(url: item.url).ignoresSafeArea() }
        .sheet(isPresented: $showNow) {
            NowPlayingView()
                .environmentObject(player)
                .environmentObject(player.time)
        }
    }

    private func placeholder(_ title: String, _ icon: String) -> some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Theme.accent)
                Text(title).font(.title2.bold())
                Text("Not part of this test").foregroundStyle(Theme.muted)
            }
        }
    }
}

struct Toast: View {
    @EnvironmentObject var player: PlayerModel
    var body: some View {
        if let m = player.message {
            Text(m)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
