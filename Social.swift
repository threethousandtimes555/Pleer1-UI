import SwiftUI

/// Подбор треков по списку исполнителей (без сервера, только открытые источники)
enum Recommender {
    static func wave(artists: [String], key: String) async -> [Track] {
        var all: [Track] = []
        await withTaskGroup(of: [Track].self) { g in
            for a in artists.prefix(8) {
                g.addTask { await Recommender.perArtist(a, key: key) }
            }
            for await r in g { all += r }
        }
        var seen = Set<String>()
        var out: [Track] = []
        for t in all.shuffled() {
            if t.archive != nil || seen.contains(t.id) { continue }
            seen.insert(t.id)
            out.append(t)
        }
        return Array(out.prefix(40))
    }

    private static func perArtist(_ a: String, key: String) async -> [Track] {
        let r = await Sources.quick(a, key: key)
        let low = a.lowercased()
        let m = r.filter { t in
            let x = t.artist.lowercased()
            return !x.isEmpty && (x.contains(low) || low.contains(x))
        }
        return Array((m.isEmpty ? r : m).prefix(6))
    }
}
