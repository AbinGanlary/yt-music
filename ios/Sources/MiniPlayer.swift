import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerModel
    let open: () -> Void
    @State private var drag: CGFloat = 0

    var body: some View {
        let t = player.current
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Cover(track: t, radius: 14).frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(t.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Button { tap(); player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                Button { tap(); player.next() } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 36, height: 40)
                }
                .buttonStyle(.plain)
            }
            MiniProgress()
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: Color.black.opacity(0.14), radius: 14, y: 5)
        .offset(x: drag)
        .contentShape(Rectangle())
        .onTapGesture { tap(); open() }
        .gesture(
            DragGesture(minimumDistance: 16)
                .onChanged { v in drag = max(-90, min(90, v.translation.width * 0.6)) }
                .onEnded { v in
                    if v.translation.width < -72 { tap(.medium); player.next() }
                    else if v.translation.width > 72 { tap(.medium); player.previous() }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = 0 }
                }
        )
    }
}

/// The thin progress bar under the mini player. It is its own view so only it redraws as the song plays.
struct MiniProgress: View {
    @EnvironmentObject var time: PlaybackClock
    var body: some View {
        ProgressView(value: min(1, time.elapsed / max(1, time.duration))).tint(Theme.accent).padding(.horizontal, 6)
    }
}
