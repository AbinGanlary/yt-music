import SwiftUI

/// Decoded covers kept in memory, so scrolling a list shows them at once instead of reloading them every time a row comes back.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private init() { cache.countLimit = 400 }

    func image(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    /// From memory, or downloaded and decoded off the main thread.
    func load(_ url: URL) async -> UIImage? {
        if let hit = image(url) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let raw = UIImage(data: data) else { return nil }
        let ready = await raw.byPreparingForDisplay() ?? raw
        cache.setObject(ready, forKey: url as NSURL)
        return ready
    }
}

/// A remote image that fills its frame. It is shown immediately when it is already cached.
struct CachedImage: View {
    let url: URL?
    @State private var img: UIImage?

    init(url: URL?) {
        self.url = url
        _img = State(initialValue: url.flatMap { ImageCache.shared.image($0) })
    }

    var body: some View {
        Group {
            if let img = img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard let u = url else { img = nil; return }
            if let c = ImageCache.shared.image(u) { img = c; return }
            img = await ImageCache.shared.load(u)
        }
    }
}

/// The gear that opens Settings. It sits in the top bar of every tab so it is always in reach.
struct SettingsButton: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var engine: EngineHost
    @State private var show = false

    var body: some View {
        Button { show = true } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
            .sheet(isPresented: $show) { SettingsView().environmentObject(player).environmentObject(engine) }
    }
}
