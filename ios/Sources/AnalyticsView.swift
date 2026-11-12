import SwiftUI

struct AnalyticsView: View {
    @EnvironmentObject var player: PlayerModel

    private struct Stat { let name: String; let secs: Double; let count: Int }

    var body: some View {
        let plays = player.lib.plays
        NavigationStack {
            ScrollView {
                if plays.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar.fill").font(.system(size: 40)).foregroundStyle(Theme.accent)
                        Text("Nothing to show yet").font(.title3.bold())
                        Text("Play some songs. Your listening time, top artists and streak are worked out here, on your phone.")
                            .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 80)
                } else {
                    content(plays)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Analytics")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { SettingsButton() } }
        }
    }

    private func duration(_ secs: Double) -> String {
        if secs < 60 { return "\(Int(secs)) sec" }
        let m = Int(secs / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    private func streak(_ plays: [PlayEvent]) -> Int {
        let cal = Calendar.current
        let days = Set(plays.map { cal.startOfDay(for: $0.at) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        var n = 0
        while days.contains(day) {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day.addingTimeInterval(-86400)
        }
        return n
    }

    private func top(_ plays: [PlayEvent], key: (PlayEvent) -> String) -> [Stat] {
        var secs: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for p in plays {
            let k = key(p)
            if k.isEmpty { continue }
            secs[k, default: 0] += p.secs
            counts[k, default: 0] += 1
        }
        return secs.map { Stat(name: $0.key, secs: $0.value, count: counts[$0.key] ?? 0) }.sorted { $0.secs > $1.secs }
    }

    private func lastSevenDays(_ plays: [PlayEvent]) -> [(label: String, mins: Double)] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return (0..<7).reversed().map { back in
            let day = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: Date())) ?? Date()
            let secs = plays.filter { cal.isDate($0.at, inSameDayAs: day) }.reduce(0) { $0 + $1.secs }
            return (f.string(from: day), secs / 60)
        }
    }

    @ViewBuilder
    private func content(_ plays: [PlayEvent]) -> some View {
        let total = plays.reduce(0) { $0 + $1.secs }
        let days = lastSevenDays(plays)
        let peak = max(5, days.map { $0.mins }.max() ?? 5)      // a scale of at least 5 minutes, so a few seconds don't fill the chart
        let artists = top(plays) { $0.artist.components(separatedBy: ", ").first ?? "" }
        let songs = top(plays) { $0.title }

        VStack(alignment: .leading, spacing: 22) {
            wrapped(total: total, plays: plays.count, streak: streak(plays), artist: artists.first?.name, song: songs.first?.name)

            HStack(spacing: 10) {
                tile("Listening time", duration(total))
                tile("Songs played", "\(plays.count)")
                tile("Day streak", "\(streak(plays))")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Last 7 days").font(.title3.bold())
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                        VStack(spacing: 6) {
                            Text(d.mins >= 1 ? "\(Int(d.mins))" : "").font(.caption2).foregroundStyle(Theme.muted)
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                                .frame(height: max(3, 110 * d.mins / peak))
                            Text(d.label).font(.caption2).foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 150, alignment: .bottom)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            hourCard(plays)

            ranking("Top artists", Array(artists.prefix(5)))
            ranking("Top songs", Array(songs.prefix(5)))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 140)
    }

    /// A Wrapped-style summary card you can share as text.
    private func wrapped(total: Double, plays: Int, streak: Int, artist: String?, song: String?) -> some View {
        let text = "My listening on YT Music: \(duration(total)) across \(plays) songs" + (artist.map { ", top artist \($0)" } ?? "") + (song.map { ", top song \($0)" } ?? "") + (streak > 1 ? ", \(streak) day streak." : ".")
        return VStack(alignment: .leading, spacing: 10) {
            Text("YOUR LISTENING, SO FAR").font(.caption.weight(.bold)).tracking(1.2).opacity(0.85)
            Text(duration(total)).font(.system(size: 40, weight: .heavy, design: .rounded))
            HStack(alignment: .top, spacing: 16) {
                if let a = artist { VStack(alignment: .leading, spacing: 2) { Text("Top artist").font(.caption).opacity(0.8); Text(a).font(.subheadline.weight(.bold)).lineLimit(2) } }
                if let s = song { VStack(alignment: .leading, spacing: 2) { Text("Top song").font(.caption).opacity(0.8); Text(s).font(.subheadline.weight(.bold)).lineLimit(2) } }
            }
            ShareLink(item: text) {
                Label("Share", systemImage: "square.and.arrow.up").font(.footnote.weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.white.opacity(0.22), in: Capsule())
            }
        }
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LinearGradient(colors: [Theme.accent, Color(hex: "#7c5cff")], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    /// Minutes listened in each hour of the day.
    private func byHour(_ plays: [PlayEvent]) -> [Double] {
        var mins = [Double](repeating: 0, count: 24)
        let cal = Calendar.current
        for p in plays { mins[cal.component(.hour, from: p.at)] += p.secs / 60 }
        return mins
    }

    private func hourName(_ h: Int) -> String {
        let n = h % 12 == 0 ? 12 : h % 12
        return "\(n) \(h < 12 ? "AM" : "PM")"
    }

    private func hourCard(_ plays: [PlayEvent]) -> some View {
        let hours = byHour(plays)
        let peak = max(5, hours.max() ?? 5)
        let best = hours.firstIndex(of: hours.max() ?? 0) ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("By hour of the day").font(.title3.bold())
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { h in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(h == best ? Theme.accent : Theme.accent.opacity(0.45))
                        .frame(height: max(3, 80 * hours[h] / peak))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 80, alignment: .bottom)
            HStack {
                ForEach(["12 AM", "6 AM", "12 PM", "6 PM"], id: \.self) { l in
                    Text(l).font(.caption2).foregroundStyle(Theme.muted)
                    if l != "6 PM" { Spacer() }
                }
            }
            if (hours.max() ?? 0) > 0 {
                Text("You listen most around \(hourName(best)).").font(.footnote).foregroundStyle(Theme.muted)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.bold()).minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.caption).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func ranking(_ title: String, _ rows: [Stat]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            let best = max(1, rows.first?.secs ?? 1)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(i + 1)").font(.subheadline.bold()).foregroundStyle(Theme.accent).frame(width: 22, alignment: .leading)
                        Text(r.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text(duration(r.secs)).font(.caption).foregroundStyle(Theme.muted)
                    }
                    GeometryReader { g in
                        Capsule().fill(Theme.accent.opacity(0.85)).frame(width: max(4, g.size.width * r.secs / best), height: 4)
                    }
                    .frame(height: 4)
                }
            }
        }
    }
}
