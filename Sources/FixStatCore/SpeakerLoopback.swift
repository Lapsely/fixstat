import AVFoundation
import Foundation

/// Plays tones on each speaker and listens with the built-in microphone: a speaker that stays
/// silent, one far quieter than the other, or one that distorts (rattle, torn cone) shows without
/// listening by ear. The left and right speakers play different frequencies (300 … 4,800 Hz and
/// 350 … 5,600 Hz), so the recording needs no timing: each tone is found by its frequency
/// (Goertzel), against the noise at that frequency before the tones start.
public final class SpeakerLoopback {
    public enum State: Equatable { case idle, running, finished, failed(String) }

    public static let leftFrequencies: [Double] = [300, 600, 1_200, 2_400, 4_800]
    public static let rightFrequencies: [Double] = [350, 700, 1_400, 2_800, 5_600]
    static let toneSeconds = 0.4
    static let leadSeconds = 0.6

    public private(set) var state = State.idle
    public private(set) var result: LoopbackResult?
    public var onChange: (() -> Void)?

    private var input: AVAudioEngine?
    private var output: AVAudioEngine?
    private var samples: [Float] = []
    private var sampleRate = 48_000.0
    private let lock = NSLock()

    public init() {}

    /// Built-in speakers and microphone, not muted and loud enough; nil when ready.
    public static func setupProblem() -> String? {
        guard let out = AudioDevice.defaultDevice(input: false), out.isBuiltIn else {
            return L("Choose the built-in speakers as the sound output (headphones or an external device is selected).")
        }
        guard let mic = AudioDevice.defaultDevice(input: true), mic.isBuiltIn else {
            return L("Choose the built-in microphone as the sound input.")
        }
        if out.muted == true || (out.volume ?? 1) < 0.4 {
            return L("Turn the volume up to at least half and unmute the Mac.")
        }
        return nil
    }

    public func start() {
        guard state != .running else { return }
        if let problem = Self.setupProblem() {
            state = .failed(problem)
            onChange?()
            return
        }
        MediaPermission.request(.audio) { [weak self] permission in
            guard let self else { return }
            guard permission == .granted else {
                state = .failed(L("FixStat may not use the microphone: allow it under Privacy & Security › Microphone."))
                onChange?()
                return
            }
            run()
        }
    }

    private func run() {
        samples = []
        let input = AVAudioEngine()
        let format = input.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { fail(L("The microphone delivers no sound.")); return }
        sampleRate = format.sampleRate
        input.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let values = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            lock.lock()
            samples += values
            lock.unlock()
        }
        do { try input.start() } catch { fail(L("The microphone could not be started.")); return }
        self.input = input
        state = .running
        onChange?()

        let output = AVAudioEngine()
        let rate = output.outputNode.outputFormat(forBus: 0).sampleRate > 0 ? output.outputNode.outputFormat(forBus: 0).sampleRate : 48_000
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = Self.render(format: stereo) else { fail(L("The tones could not be played.")); return }
        let node = AVAudioPlayerNode()
        output.attach(node)
        output.connect(node, to: output.mainMixerNode, format: stereo)
        do { try output.start() } catch { fail(L("The tones could not be played.")); return }
        self.output = output
        // The microphone hears the room for `leadSeconds` first: the noise floor per frequency.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leadSeconds) {
            node.scheduleBuffer(buffer, completionHandler: nil)
            node.play()
        }
        let total = Self.leadSeconds + Double(buffer.frameLength) / rate + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak self] in self?.finish() }
    }

    private func fail(_ message: String) {
        stopEngines()
        state = .failed(message)
        onChange?()
    }

    private func stopEngines() {
        input?.inputNode.removeTap(onBus: 0)
        input?.stop()
        input = nil
        output?.stop()
        output = nil
    }

    private func finish() {
        stopEngines()
        lock.lock()
        let recorded = samples
        lock.unlock()
        result = LoopbackResult.analyze(recorded, sampleRate: sampleRate, leadSeconds: Self.leadSeconds)
        state = .finished
        onChange?()
    }

    public func stop() {
        stopEngines()
        if state == .running { state = .idle; onChange?() }
    }

    /// Left tones on the left channel, then right tones on the right, each faded in and out.
    static func render(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let toneFrames = Int(toneSeconds * rate)
        let tones = leftFrequencies.map { ($0, 0) } + rightFrequencies.map { ($0, 1) }
        let total = toneFrames * tones.count
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)
        let fade = Int(rate * 0.02)
        for (index, (frequency, channel)) in tones.enumerated() {
            for i in 0..<toneFrames {
                let envelope = Float(min(1, Double(i) / Double(fade), Double(toneFrames - i) / Double(fade)))
                let value = Float(sin(2 * .pi * frequency * Double(i) / rate)) * 0.5 * envelope
                let frame = index * toneFrames + i
                channels[channel][frame] = value
                channels[1 - channel][frame] = 0
            }
        }
        return buffer
    }
}

/// What the microphone heard of each tone.
public struct LoopbackResult: Equatable {
    public struct Tone: Equatable {
        public let frequency: Double
        /// Level above the noise at that frequency before the tones, dB.
        public let aboveNoise: Double
        /// 2nd + 3rd harmonics relative to the tone, dB (more negative = cleaner).
        public let harmonics: Double?
    }

    public let left: [Tone]
    public let right: [Tone]

    /// A speaker is heard when its tones stand this far above the noise (median of its tones).
    public static let heardLimit = 10.0
    /// A speaker this much quieter than the other (median over its tones) is reported.
    public static let imbalanceLimit = 15.0
    /// Harmonics this close to the tone (mid frequencies) point to a rattle or a torn cone.
    public static let distortionLimit = -12.0

    public var leftLevel: Double { Self.median(left.map(\.aboveNoise)) }
    public var rightLevel: Double { Self.median(right.map(\.aboveNoise)) }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    /// Harmonics of the 600 / 700 and 1,200 / 1,400 Hz tones (low tones distort in any small
    /// speaker, high ones have their harmonics above the microphone's range).
    func distortion(_ tones: [Tone]) -> Double? {
        let mid = tones.filter { (500...1_500).contains($0.frequency) && $0.aboveNoise >= Self.heardLimit }.compactMap(\.harmonics)
        return mid.isEmpty ? nil : mid.max()
    }

    public var leftDistortion: Double? { distortion(left) }
    public var rightDistortion: Double? { distortion(right) }

    public enum Finding: Equatable {
        case silent(left: Bool)
        case quieter(left: Bool, by: Double)
        case distorted(left: Bool, harmonics: Double)
    }

    public var findings: [Finding] {
        var out: [Finding] = []
        let leftHeard = leftLevel >= Self.heardLimit, rightHeard = rightLevel >= Self.heardLimit
        if !leftHeard { out.append(.silent(left: true)) }
        if !rightHeard { out.append(.silent(left: false)) }
        if leftHeard, rightHeard {
            if rightLevel - leftLevel >= Self.imbalanceLimit { out.append(.quieter(left: true, by: rightLevel - leftLevel)) }
            if leftLevel - rightLevel >= Self.imbalanceLimit { out.append(.quieter(left: false, by: leftLevel - rightLevel)) }
        }
        if let d = leftDistortion, d >= Self.distortionLimit { out.append(.distorted(left: true, harmonics: d)) }
        if let d = rightDistortion, d >= Self.distortionLimit { out.append(.distorted(left: false, harmonics: d)) }
        return out
    }

    /// `samples`: the recording, `leadSeconds` of room noise first.
    public static func analyze(_ samples: [Float], sampleRate: Double, leadSeconds: Double) -> LoopbackResult {
        let window = Int(0.25 * sampleRate), hop = window / 2
        let lead = min(samples.count, Int(leadSeconds * sampleRate) - Int(0.1 * sampleRate))
        func strongest(_ frequency: Double, from start: Int) -> (power: Double, at: Int) {
            var best = (power: 0.0, at: start)
            var i = start
            while i + window <= samples.count {
                let p = goertzel(samples, from: i, count: window, frequency: frequency, sampleRate: sampleRate)
                if p > best.power { best = (p, i) }
                i += hop
            }
            return best
        }
        func noise(_ frequency: Double) -> Double {
            guard lead >= window else { return 1e-12 }
            var values: [Double] = []
            var i = 0
            while i + window <= lead {
                values.append(goertzel(samples, from: i, count: window, frequency: frequency, sampleRate: sampleRate))
                i += hop
            }
            return max(values.max() ?? 1e-12, 1e-12)
        }
        func tone(_ frequency: Double) -> Tone {
            let peak = strongest(frequency, from: max(0, lead))
            let floor = noise(frequency)
            let aboveNoise = 10 * log10(max(peak.power, 1e-12) / floor)
            var harmonics: Double?
            if peak.power > 0, 3 * frequency < sampleRate / 2 {
                let h = [2.0, 3.0].map { goertzel(samples, from: peak.at, count: window, frequency: $0 * frequency, sampleRate: sampleRate) }
                harmonics = 10 * log10(max(h.reduce(0, +), 1e-15) / peak.power)
            }
            return Tone(frequency: frequency, aboveNoise: (aboveNoise * 10).rounded() / 10,
                        harmonics: harmonics.map { ($0 * 10).rounded() / 10 })
        }
        return LoopbackResult(left: SpeakerLoopback.leftFrequencies.map(tone), right: SpeakerLoopback.rightFrequencies.map(tone))
    }

    /// Power of one frequency in a block (Goertzel), normalised by the block length.
    static func goertzel(_ x: [Float], from start: Int, count: Int, frequency: Double, sampleRate: Double) -> Double {
        let k = 2 * cos(2 * .pi * frequency / sampleRate)
        var s1 = 0.0, s2 = 0.0
        for i in start..<(start + count) {
            let s0 = Double(x[i]) + k * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - k * s1 * s2
        return power / Double(count * count)
    }
}

/// Texts of the speaker check (both interfaces).
public enum LoopbackText {
    public static var explanation: String {
        L("Plays tones on each speaker and listens with the built-in microphone: a silent speaker, one far quieter than the other or one that distorts (rattle, torn cone) shows without listening by ear. Keep the room quiet and the lid open; about 6 s.")
    }

    /// "Left speaker: 300 – 4,800 Hz, +18 … +41 dB above the room"
    public static func rows(_ r: LoopbackResult) -> [(String, String)] {
        func row(_ tones: [LoopbackResult.Tone], distortion: Double?) -> String {
            let levels = tones.map(\.aboveNoise)
            var text = L("%1$@ … %2$@ above the room", Format.decibels(levels.min() ?? 0, unit: "dB"),
                         Format.decibels(levels.max() ?? 0, unit: "dB"))
            if let distortion { text += " · " + L("harmonics %@", Format.decibels(distortion, unit: "dB")) }
            return text
        }
        return [(L("Left speaker"), row(r.left, distortion: r.leftDistortion)),
                (L("Right speaker"), row(r.right, distortion: r.rightDistortion))]
    }

    public static func finding(_ f: LoopbackResult.Finding) -> String {
        switch f {
        case let .silent(left):
            return left ? L("The microphone did not hear the left speaker: the speaker, its cable or the amplifier.")
                : L("The microphone did not hear the right speaker: the speaker, its cable or the amplifier.")
        case let .quieter(left, by):
            return L("The %1$@ speaker is %2$@ quieter than the other: a weak or blocked speaker.",
                     left ? L("left") : L("right"), Format.decibels(by, unit: "dB"))
        case let .distorted(left, harmonics):
            return L("The %1$@ speaker distorts (harmonics %2$@): listen for a rattle or buzz, a torn cone or a loose part.",
                     left ? L("left") : L("right"), Format.decibels(harmonics, unit: "dB"))
        }
    }

    public static func summary(_ r: LoopbackResult) -> String {
        let findings = r.findings
        return findings.isEmpty ? L("Both speakers heard clearly by the microphone") : findings.map(finding).joined(separator: " ")
    }
}
