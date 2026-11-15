import Foundation
import AVFoundation
import MediaPlayer
import UIKit

enum RepeatMode: String {
    case off, all, one, shuffle

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }
    var label: String {
        switch self {
        case .off: return "Повтор выключен"
        case .all: return "Повтор всех треков"
        case .one: return "Повтор одного трека"
        case .shuffle: return "Вперемешку"
        }
    }
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .shuffle
        case .shuffle: return .off
        }
    }
}

@MainActor
final class Player: ObservableObject {
    @Published var queue: [Track] = []
    @Published var index: Int = 0
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var sleepMinutes = 0
    @Published var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "rm") ?? "off") ?? .off
    @Published var speed: Double = {
        let v = UserDefaults.standard.double(forKey: "sp")
        return v == 0 ? 1.0 : v
    }()

    weak var store: Store?

    var current: Track? {
        return queue.indices.contains(index) ? queue[index] : nil
    }

    private let player = AVPlayer()
    private var timeObs: Any?
    private var endObs: NSObjectProtocol?
    private var sleepTask: Task<Void, Never>?

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in self?.tick(t) }
        }

        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let typeRaw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let optRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let ended = AVAudioSession.InterruptionType(rawValue: typeRaw) == .ended
            let should = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            Task { @MainActor in
                if ended && should { self?.resume() }
            }
        }
        setupRemote()
    }

    // MARK: playback
    func play(_ list: [Track], at i: Int = 0) {
        if list.isEmpty { return }
        queue = list
        index = max(0, min(i, list.count - 1))
        load()
    }

    func jump(to i: Int) {
        if queue.indices.contains(i) {
            index = i
            load()
        }
    }

    private func playURL(_ t: Track) -> URL? {
        if let f = t.file { return Store.musicDir.appendingPathComponent(f) }
        if let u = t.url { return URL(string: u) }
        return nil
    }

    private func load() {
        guard let t = current else { return }
        if t.archive != nil {
            Task { await expandArchive(t) }
            return
        }
        guard let url = playURL(t) else {
            store?.say("Файл не найден")
            return
        }
        let item = AVPlayerItem(url: url)
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.advance(auto: true) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        player.rate = Float(speed)
        position = 0
        duration = 0
        isPlaying = true
        store?.addHistory(t)
        updateNowPlaying()
    }

    private func expandArchive(_ t: Track) async {
        guard let id = t.archive else { return }
        store?.say("Загружаю…")
        let tracks = await Sources.archiveTracks(id: id, title: t.title, art: t.art)
        if tracks.isEmpty {
            store?.say("В этой записи нет mp3")
            return
        }
        queue = tracks
        index = 0
        load()
    }

    func resume() {
        player.play()
        player.rate = Float(speed)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() {
        if player.timeControlStatus == .paused { resume() } else { pause() }
    }

    func advance(auto: Bool = false) {
        if queue.isEmpty { return }
        if repeatMode == .one && auto {
            load()
            return
        }
        if repeatMode == .shuffle && queue.count > 1 {
            var j = index
            while j == index { j = Int.random(in: 0..<queue.count) }
            index = j
            load()
            return
        }
        if index < queue.count - 1 {
            index += 1
            load()
        } else if repeatMode == .all || repeatMode == .one {
            index = 0
            load()
        } else if auto {
            isPlaying = false
        }
    }

    func previous() {
        if position > 3 {
            seek(0)
        } else if index > 0 {
            index -= 1
            load()
        } else {
            seek(0)
        }
    }

    func seek(_ s: Double) {
        player.seek(to: CMTime(seconds: s, preferredTimescale: 600))
        position = s
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        UserDefaults.standard.set(repeatMode.rawValue, forKey: "rm")
        store?.say(repeatMode.label)
    }

    func setSpeed(_ v: Double) {
        speed = v
        UserDefaults.standard.set(v, forKey: "sp")
        if player.timeControlStatus != .paused { player.rate = Float(v) }
    }

    func setSleep(_ m: Int) {
        sleepTask?.cancel()
        sleepMinutes = m
        if m <= 0 { return }
        sleepTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(m) * 60_000_000_000)
            if !Task.isCancelled {
                self.pause()
                self.sleepMinutes = 0
            }
        }
    }

    private func tick(_ t: CMTime) {
        let s = t.seconds
        position = s.isFinite ? s : 0
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        isPlaying = player.timeControlStatus != .paused
        updateProgress()
    }

    // MARK: lock screen
    private func updateNowPlaying() {
        guard let t = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0
        ]
        info[MPMediaItemPropertyPlaybackDuration] = 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if let a = t.art, let u = URL(string: a) {
            Task {
                if let r = try? await URLSession.shared.data(from: u), let img = UIImage(data: r.0) {
                    let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    cur[MPMediaItemPropertyArtwork] = art
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
                }
            }
        }
    }

    private func updateProgress() {
        var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        cur[MPMediaItemPropertyPlaybackDuration] = duration
        cur[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        cur[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.advance() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let ev = e as? MPChangePlaybackPositionCommandEvent {
                let pos = ev.positionTime
                Task { @MainActor in self?.seek(pos) }
            }
            return .success
        }
    }
}
