import Foundation
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var favorites: [Track] = [] { didSet { save("fav", favorites) } }
    @Published var playlists: [Playlist] = [] { didSet { save("pls", playlists) } }
    @Published var history: [Track] = [] { didSet { save("his", history) } }
    @Published var overrides: [String: [String]] = [:] { didSet { save("ovr", overrides) } }
    @Published var files: [Track] = []
    @Published var toast: String? = nil
    @Published var jamendoKey: String = UserDefaults.standard.string(forKey: "jk") ?? "" {
        didSet { UserDefaults.standard.set(jamendoKey, forKey: "jk") }
    }
    @Published var funkHost: String = UserDefaults.standard.string(forKey: "fh") ?? "open.audio" {
        didSet { UserDefaults.standard.set(funkHost, forKey: "fh") }
    }

    static let musicDir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Music")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() {
        favorites = load("fav") ?? []
        playlists = load("pls") ?? []
        history = load("his") ?? []
        overrides = load("ovr") ?? [:]
        scanFiles()
    }

    private func save<T: Encodable>(_ key: String, _ value: T) {
        if let d = try? JSONEncoder().encode(value) { UserDefaults.standard.set(d, forKey: key) }
    }
    private func load<T: Decodable>(_ key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    func say(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if self.toast == s { self.toast = nil }
        }
    }

    // MARK: files
    func scanFiles() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Store.musicDir.path)) ?? []
        let exts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "caf", "opus"]
        var out: [Track] = []
        for n in names.sorted() {
            let ext = (n as NSString).pathExtension.lowercased()
            if !exts.contains(ext) { continue }
            let p = Store.musicDir.appendingPathComponent(n).path
            let attrs = try? fm.attributesOfItem(atPath: p)
            let date = (attrs?[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let o = overrides[n]
            let base = (n as NSString).deletingPathExtension
            out.append(Track(id: "l" + n, title: o?[0] ?? base, artist: o?[1] ?? "С телефона", file: n, added: date))
        }
        files = out
    }

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let name = url.lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var dest = Store.musicDir.appendingPathComponent(name)
        var i = 1
        while fm.fileExists(atPath: dest.path) {
            dest = Store.musicDir.appendingPathComponent("\(base) \(i).\(ext)")
            i += 1
        }
        do {
            try fm.copyItem(at: url, to: dest)
            scanFiles()
            say("Добавлено: " + base)
        } catch {
            say("Не получилось добавить файл")
        }
    }

    func deleteFile(_ t: Track) {
        guard let f = t.file else { return }
        try? FileManager.default.removeItem(at: Store.musicDir.appendingPathComponent(f))
        overrides[f] = nil
        scanFiles()
    }

    var library: [Track] {
        return (files + favorites).sorted { $0.added > $1.added }
    }

    // MARK: favorites / history
    func isFav(_ t: Track) -> Bool { return favorites.contains { $0.id == t.id } }

    func toggleFav(_ t: Track) {
        if let i = favorites.firstIndex(where: { $0.id == t.id }) {
            favorites.remove(at: i)
        } else {
            var x = t
            x.added = Date().timeIntervalSince1970
            favorites.insert(x, at: 0)
        }
    }

    func addHistory(_ t: Track) {
        history.removeAll { $0.id == t.id }
        history.insert(t, at: 0)
        if history.count > 40 { history.removeLast(history.count - 40) }
    }

    func rename(_ t: Track, title: String, artist: String) {
        let ti = title.isEmpty ? t.title : title
        let ar = artist.isEmpty ? t.artist : artist
        if let f = t.file {
            overrides[f] = [ti, ar]
            scanFiles()
        }
        func patch(_ arr: inout [Track]) {
            for i in arr.indices where arr[i].id == t.id {
                arr[i].title = ti
                arr[i].artist = ar
            }
        }
        patch(&favorites)
        patch(&history)
        for p in playlists.indices { patch(&playlists[p].tracks) }
    }

    // MARK: playlists
    @discardableResult
    func createPlaylist(_ name: String) -> UUID? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return nil }
        let p = Playlist(name: n)
        playlists.append(p)
        return p.id
    }

    func add(_ t: Track, to id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        if playlists[i].tracks.contains(where: { $0.id == t.id }) {
            say("Уже в «" + playlists[i].name + "»")
        } else {
            playlists[i].tracks.append(t)
            say("Добавлено в «" + playlists[i].name + "»")
        }
    }

    func removeFromPlaylist(_ t: Track, _ id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.removeAll { $0.id == t.id }
    }

    func renamePlaylist(_ id: UUID, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return }
        if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].name = n }
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
    }
}
