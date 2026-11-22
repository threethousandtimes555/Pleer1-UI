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

/// Часто меняющиеся значения вынесены отдельно, чтобы не перерисовывать списки
@MainActor
final class Clock: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
}

@MainActor
final class Player: ObservableObject {
    @Published var queue: [Track] = []
    @Published var index: Int = 0
    @Published var isPlaying = false
    @Published var sleepMinutes = 0
    @Published var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "rm") ?? "off") ?? .off
    @Published var speed: Double = {
        let v = UserDefaults.standard.double(forKey: "sp")
        return v == 0 ? 1.0 : v
    }()

    @Published var eqPreset: EQPreset = EQPreset(rawValue: UserDefaults.standard.string(forKey: "eq") ?? "off") ?? .off
    @Published var crossfade: Int = UserDefaults.standard.integer(forKey: "xf")

    let clock = Clock()
    weak var store: Store?

    var current: Track? {
        return queue.indices.contains(index) ? queue[index] : nil
    }

    private let player = AVPlayer()
    private var timeObs: Any?
    private var endObs: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var sleepTask: Task<Void, Never>?
    private var loadToken = 0
    private var plannedNext: Int? = nil
    private let fx = FX()
    private var fxMode = false
    private var fxTask: Task<Void, Never>?
    private var pendingSeek: Double? = nil
    private var useFX: Bool { return crossfade > 0 || eqPreset != .off }

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        player.automaticallyWaitsToMinimizeStalling = true

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
        Task.detached { AudioCache.shared.trim() }
        fx.onFinish = { [weak self] in self?.advance(auto: true) }
        fxTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.fxTick()
            }
        }
    }

    // MARK: queue
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

    private func planNext() {
        if queue.count < 2 {
            plannedNext = repeatMode == .off ? nil : (queue.isEmpty ? nil : index)
            return
        }
        switch repeatMode {
        case .shuffle:
            var j = index
            while j == index { j = Int.random(in: 0..<queue.count) }
            plannedNext = j
        case .one:
            plannedNext = index
        case .all:
            plannedNext = index < queue.count - 1 ? index + 1 : 0
        case .off:
            plannedNext = index < queue.count - 1 ? index + 1 : nil
        }
    }

    // MARK: loading
    private func localURL(_ t: Track) -> URL? {
        if let f = t.file { return Paths.music.appendingPathComponent(f) }
        return AudioCache.shared.lookup(t)
    }

    private func load() {
        guard let t = current else { return }
        loadToken += 1
        planNext()
        if t.archive != nil {
            Task { await expandArchive(t) }
            return
        }
        let from = pendingSeek ?? 0
        pendingSeek = nil
        clock.position = from
        clock.duration = 0
        isPlaying = true
        store?.addHistory(t)
        if useFX {
            loadFX(t, loadToken, from)
        } else {
            if fxMode {
                fx.stopAll()
                fxMode = false
            }
            if let url = localURL(t) {
                start(url, t, streaming: false)
            } else if let s = t.url, let u = URL(string: s) {
                start(u, t, streaming: true)
            } else {
                store?.say("Файл не найден")
            }
            if from > 0 { player.seek(to: CMTime(seconds: from, preferredTimescale: 600)) }
        }
        updateNowPlaying()
    }

    private func start(_ url: URL, _ t: Track, streaming: Bool) {
        let asset: AVURLAsset
        if url.isFileURL {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Plei/0.2"]])
        }
        let item = AVPlayerItem(asset: asset)
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.advance(auto: true) }
        }
        let token = loadToken
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            let st = it.status
            let msg = it.error?.localizedDescription ?? ""
            Task { @MainActor in self?.itemStatus(st, msg, t, token, streaming) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        player.rate = Float(speed)
    }

    private func itemStatus(_ st: AVPlayerItem.Status, _ msg: String, _ t: Track, _ token: Int, _ streaming: Bool) {
        if token != loadToken { return }
        if st == .readyToPlay {
            updateNowPlaying()
            prefetchNext()
        } else if st == .failed {
            if streaming {
                Task { await recover(t, token) }
            } else {
                store?.say("Не воспроизводится: " + msg)
            }
        }
    }

    /// Если поток не открылся, скачиваем трек целиком и играем из файла
    private func recover(_ t: Track, _ token: Int) async {
        store?.say("Докачиваю трек целиком…")
        do {
            let u = try await AudioCache.shared.download(t)
            if token == loadToken { start(u, t, streaming: false) }
        } catch {
            if token == loadToken { store?.say("Не получилось: " + error.localizedDescription) }
        }
    }

    /// Следующий трек подгружается заранее, чтобы переключение не лагало
    private func prefetchNext() {
        guard let n = plannedNext, queue.indices.contains(n) else { return }
        let t = queue[n]
        if t.file != nil || t.archive != nil || t.url == nil { return }
        Task.detached(priority: .utility) {
            _ = try? await AudioCache.shared.download(t)
        }
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

    // MARK: controls
    func resume() {
        if fxMode {
            try? fx.resume()
        } else {
            player.play()
            player.rate = Float(speed)
        }
        isPlaying = true
        updateProgress()
    }

    func pause() {
        if fxMode { fx.pause() } else { player.pause() }
        isPlaying = false
        updateProgress()
    }

    func toggle() {
        if fxMode {
            if isPlaying { pause() } else { resume() }
        } else if player.timeControlStatus == .paused {
            resume()
        } else {
            pause()
        }
    }

    func advance(auto: Bool = false) {
        if queue.isEmpty { return }
        var j: Int? = nil
        if auto || repeatMode != .one { j = plannedNext }
        if j == nil {
            if index < queue.count - 1 { j = index + 1 } else if repeatMode != .off { j = 0 }
        }
        if let n = j {
            index = n
            load()
        } else if auto {
            isPlaying = false
        }
    }

    func previous() {
        if clock.position > 3 {
            seek(0)
        } else if index > 0 {
            index -= 1
            load()
        } else {
            seek(0)
        }
    }

    func seek(_ s: Double) {
        if fxMode {
            try? fx.seek(to: s)
        } else {
            player.seek(to: CMTime(seconds: s, preferredTimescale: 600))
        }
        clock.position = s
        updateProgress()
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        UserDefaults.standard.set(repeatMode.rawValue, forKey: "rm")
        planNext()
        store?.say(repeatMode.label)
    }

    func setSpeed(_ v: Double) {
        speed = v
        UserDefaults.standard.set(v, forKey: "sp")
        if fxMode {
            fx.apply(gains: eqPreset.gains, rate: Float(v))
        } else if player.timeControlStatus != .paused {
            player.rate = Float(v)
        }
        updateProgress()
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
        if fxMode { return }
        let s = t.seconds
        clock.position = s.isFinite ? s : 0
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - clock.duration) > 0.5 {
            clock.duration = d
            updateProgress()
        }
        let playing = player.timeControlStatus != .paused
        if playing != isPlaying {
            isPlaying = playing
            updateProgress()
        }
    }

    // MARK: эффекты (эквалайзер и наслоение)
    func setEQ(_ p: EQPreset) {
        eqPreset = p
        UserDefaults.standard.set(p.rawValue, forKey: "eq")
        effectsChanged()
    }

    func setCrossfade(_ s: Int) {
        crossfade = s
        UserDefaults.standard.set(s, forKey: "xf")
        effectsChanged()
    }

    private func effectsChanged() {
        if fxMode { fx.apply(gains: eqPreset.gains, rate: Float(speed)) }
        if useFX != fxMode, current != nil {
            pendingSeek = clock.position
            load()
        }
        if useFX {
            store?.say("Эффекты работают для mp3, m4a, wav и flac. Стриминговые треки сначала докачиваются.")
        }
    }

    private func loadFX(_ t: Track, _ token: Int, _ from: Double) {
        if let url = localURL(t) {
            startFX(url, t, from)
            return
        }
        guard t.url != nil else {
            store?.say("Файл не найден")
            return
        }
        player.pause()
        if fxMode { fx.stopAll() }
        fxMode = false
        store?.say("Загружаю трек…")
        Task {
            do {
                let u = try await AudioCache.shared.download(t)
                if token == loadToken { startFX(u, t, from) }
            } catch {
                if token == loadToken { store?.say("Не получилось: " + error.localizedDescription) }
            }
        }
    }

    private func startFX(_ url: URL, _ t: Track, _ from: Double) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        do {
            try fx.start(url: url, from: from)
            fx.apply(gains: eqPreset.gains, rate: Float(speed))
            fxMode = true
            isPlaying = true
            clock.duration = fx.duration()
            updateNowPlaying()
            prefetchNext()
        } catch {
            fxMode = false
            store?.say("Эффекты не сработали, играю обычным способом")
            start(url, t, streaming: false)
            if from > 0 { player.seek(to: CMTime(seconds: from, preferredTimescale: 600)) }
        }
    }

    private func fxTick() {
        if !fxMode { return }
        let pos = fx.position()
        clock.position = pos
        let d = fx.duration()
        if abs(d - clock.duration) > 0.5 {
            clock.duration = d
            updateProgress()
        }
        let xf = Double(crossfade)
        if xf <= 0 || !isPlaying || fx.fading || d <= xf * 2 || d - pos > xf { return }
        guard let j = plannedNext, j != index, queue.indices.contains(j) else { return }
        let n = queue[j]
        if n.archive != nil { return }
        guard let u = localURL(n) else { return }
        do {
            try fx.crossfade(to: u, seconds: xf)
            index = j
            loadToken += 1
            planNext()
            clock.position = 0
            clock.duration = fx.duration()
            store?.addHistory(n)
            updateNowPlaying()
            prefetchNext()
        } catch {
            // не вышло: трек просто сменится обычным образом
        }
    }

    // MARK: lock screen
    private func updateNowPlaying() {
        guard let t = current else { return }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: clock.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let id = t.id
        Task {
            var img: UIImage? = nil
            if let f = t.artFile {
                img = ImageStore.shared.local(f)
            } else if let a = t.art {
                img = await ImageStore.shared.image(url: a)
            }
            if let image = img, self.current?.id == id {
                let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                cur[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
            }
        }
    }

    private func updateProgress() {
        var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        cur[MPMediaItemPropertyPlaybackDuration] = clock.duration
        cur[MPNowPlayingInfoPropertyElapsedPlaybackTime] = clock.position
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
