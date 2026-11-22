import Foundation
import AVFoundation

enum EQPreset: String, CaseIterable {
    case off, bass, vocal, bright

    var title: String {
        switch self {
        case .off: return "Выкл"
        case .bass: return "Больше баса"
        case .vocal: return "Вокал"
        case .bright: return "Яркий звук"
        }
    }

    var gains: [Float] {
        switch self {
        case .off: return [0, 0, 0]
        case .bass: return [7, 0, 0]
        case .vocal: return [-2, 4, 2]
        case .bright: return [0, 0, 6]
        }
    }
}

/// Отдельный звуковой движок для эквалайзера и наслоения треков.
/// Включается только когда один из эффектов выбран, иначе играет обычный AVPlayer.
@MainActor
final class FX {
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 3)
    private let pitch = AVAudioUnitTimePitch()
    private let nodes: [AVAudioPlayerNode] = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private var files: [AVAudioFile?] = [nil, nil]
    private var urls: [URL?] = [nil, nil]
    private var offsets: [Double] = [0, 0]
    private var tokens: [Int] = [0, 0]
    private var active = 0
    private var pausedAt: Double? = nil
    private var fadeTask: Task<Void, Never>?
    private var built = false
    private(set) var fading = false
    var onFinish: (@MainActor () -> Void)?

    init() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartAfterChange() }
        }
    }

    private func build() {
        if built { return }
        built = true
        engine.attach(mixer)
        engine.attach(eq)
        engine.attach(pitch)
        for n in nodes {
            engine.attach(n)
            engine.connect(n, to: mixer, format: nil)
        }
        engine.connect(mixer, to: pitch, format: nil)
        engine.connect(pitch, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        let types: [AVAudioUnitEQFilterType] = [.lowShelf, .parametric, .highShelf]
        let freqs: [Float] = [100, 1500, 6000]
        for i in 0..<3 {
            let b = eq.bands[i]
            b.filterType = types[i]
            b.frequency = freqs[i]
            b.bandwidth = 1.0
            b.gain = 0
            b.bypass = false
        }
        engine.prepare()
    }

    private func ensureRunning() throws {
        if !engine.isRunning { try engine.start() }
    }

    private func prepare(_ i: Int, url: URL, from: Double) throws {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let node = nodes[i]
        node.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: mixer, format: fmt)
        files[i] = file
        urls[i] = url
        offsets[i] = from
        tokens[i] += 1
        let tk = tokens[i]
        let start = AVAudioFramePosition(max(0, from) * fmt.sampleRate)
        let total = file.length - start
        if total <= 0 {
            throw NSError(domain: "fx", code: 1, userInfo: [NSLocalizedDescriptionKey: "пустой отрезок"])
        }
        node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(total), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(i, tk) }
        }
    }

    private func finished(_ i: Int, _ tk: Int) {
        if i == active && tk == tokens[i] && pausedAt == nil { onFinish?() }
    }

    func start(url: URL, from: Double = 0) throws {
        build()
        cancelFade()
        for n in nodes {
            n.stop()
            n.volume = 1
        }
        active = 0
        try prepare(0, url: url, from: from)
        try ensureRunning()
        pausedAt = nil
        nodes[0].play()
    }

    func stopAll() {
        cancelFade()
        for n in nodes {
            n.stop()
            n.volume = 1
        }
        tokens[0] += 1
        tokens[1] += 1
        pausedAt = nil
    }

    func position() -> Double {
        if let p = pausedAt { return p }
        let n = nodes[active]
        guard let t = n.lastRenderTime, let pt = n.playerTime(forNodeTime: t), pt.sampleRate > 0 else { return offsets[active] }
        return offsets[active] + Double(pt.sampleTime) / pt.sampleRate
    }

    func duration() -> Double {
        guard let f = files[active] else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    func pause() {
        pausedAt = position()
        nodes[active].pause()
    }

    func resume() throws {
        try ensureRunning()
        pausedAt = nil
        nodes[active].play()
    }

    func seek(to s: Double) throws {
        guard let u = urls[active] else { return }
        let wasPaused = pausedAt != nil
        try prepare(active, url: u, from: s)
        try ensureRunning()
        if wasPaused {
            pausedAt = s
        } else {
            pausedAt = nil
            nodes[active].play()
        }
    }

    func apply(gains: [Float], rate: Float) {
        for i in 0..<3 { eq.bands[i].gain = gains[i] }
        pitch.rate = rate
    }

    /// Плавный переход: новый трек поднимается, прежний затихает
    func crossfade(to url: URL, seconds: Double) throws {
        try ensureRunning()
        let old = active
        let new = 1 - old
        try prepare(new, url: url, from: 0)
        nodes[new].volume = 0
        nodes[new].play()
        active = new
        pausedAt = nil
        cancelFade()
        fading = true
        let steps = max(1, Int(seconds * 20))
        fadeTask = Task {
            for k in 1...steps {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled { return }
                let p = Float(k) / Float(steps)
                self.nodes[old].volume = 1 - p
                self.nodes[new].volume = p
            }
            self.nodes[old].stop()
            self.nodes[old].volume = 1
            self.fading = false
        }
    }

    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fading = false
    }

    private func restartAfterChange() {
        if !built { return }
        guard let u = urls[active] else { return }
        let p = position()
        let wasPaused = pausedAt != nil
        try? start(url: u, from: p)
        if wasPaused { pause() }
    }
}
