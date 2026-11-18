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

struct FriendsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: Player
    @Binding var showPlayer: Bool
    @State private var busy = false
    @State private var editingName = false
    @State private var nameDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        startWave(store.myArtists().shuffled())
                    } label: {
                        Label("Моя волна", systemImage: "waveform")
                    }
                } footer: {
                    Text("Подбирает треки по твоим избранным, файлам и истории. Ищет в Jamendo, Audius и ccMixter.")
                }

                Section("Твой код вкуса") {
                    Button {
                        nameDraft = store.myName
                        editingName = true
                    } label: {
                        HStack {
                            Text("Имя")
                            Spacer()
                            Text(store.myName.isEmpty ? "не задано" : store.myName).foregroundColor(.secondary)
                        }
                    }
                    ShareLink(item: store.tasteCode()) {
                        Label("Отправить код другу", systemImage: "square.and.arrow.up")
                    }
                    Text("В коде только имя и список исполнителей. Сами треки и файлы не передаются.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Друзья") {
                    ForEach(store.friends) { f in
                        NavigationLink {
                            FriendDetailView(friend: f, showPlayer: $showPlayer)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name)
                                Text("Совпадение вкуса: \(store.match(with: f))%")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    PasteButton(payloadType: String.self) { strings in
                        guard let s = strings.first else { return }
                        if store.addFriend(s) {
                            store.say("Друг добавлен")
                        } else {
                            store.say("Это не код друга")
                        }
                    }
                    Text("Друг отправляет тебе свой код, ты копируешь его и нажимаешь «Вставить». Чтобы обновить друга, вставь его новый код.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Друзья")
            .overlay { if busy { ProgressView() } }
            .alert("Твоё имя", isPresented: $editingName) {
                TextField("Имя", text: $nameDraft)
                Button("Сохранить") { store.myName = nameDraft.trimmingCharacters(in: .whitespaces) }
                Button("Отмена", role: .cancel) {}
            }
            .safeAreaInset(edge: .bottom) { MiniPlayer(show: $showPlayer) }
        }
    }

    private func startWave(_ artists: [String]) {
        if artists.isEmpty {
            store.say("Пока мало данных: добавь треки в избранное или файлы")
            return
        }
        busy = true
        Task {
            let tracks = await Recommender.wave(artists: artists, key: store.jamendoKey)
            busy = false
            if tracks.isEmpty {
                store.say("Ничего не нашлось в открытых источниках")
            } else {
                player.play(tracks, at: 0)
            }
        }
    }
}

struct FriendDetailView: View {
    let friend: Friend
    @Binding var showPlayer: Bool
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        let common = store.common(with: friend)
        let theirs = store.only(of: friend)
        List {
            Section {
                Text("Совпадение вкуса: \(store.match(with: friend))%")
                Button {
                    play(Array(common.shuffled().prefix(4)) + Array(theirs.shuffled().prefix(4)))
                } label: {
                    Label("Волна для двоих", systemImage: "waveform")
                }
                Button {
                    play(theirs.shuffled())
                } label: {
                    Label("Что слушает " + friend.name, systemImage: "person.wave.2")
                }
            } footer: {
                Text("Волна берёт общих исполнителей и тех, кого у тебя ещё нет, и ищет их треки в открытых источниках.")
            }

            if !common.isEmpty {
                Section("Вам обоим нравится") {
                    ForEach(common, id: \.self) { a in
                        Button { play([a]) } label: {
                            HStack {
                                Text(a)
                                Spacer()
                                Image(systemName: "play.fill").foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            if !theirs.isEmpty {
                Section("У друга, но не у тебя") {
                    ForEach(theirs, id: \.self) { a in
                        Button { play([a]) } label: {
                            HStack {
                                Text(a)
                                Spacer()
                                Image(systemName: "play.fill").foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Удалить друга", role: .destructive) {
                    store.removeFriend(friend.id)
                    dismiss()
                }
            }
        }
        .navigationTitle(friend.name)
        .overlay { if busy { ProgressView() } }
        .safeAreaInset(edge: .bottom) { MiniPlayer(show: $showPlayer) }
    }

    private func play(_ artists: [String]) {
        if artists.isEmpty {
            store.say("Пока нечего подбирать")
            return
        }
        busy = true
        Task {
            let tracks = await Recommender.wave(artists: artists, key: store.jamendoKey)
            busy = false
            if tracks.isEmpty {
                store.say("Ничего не нашлось в открытых источниках")
            } else {
                player.play(tracks, at: 0)
            }
        }
    }
}
