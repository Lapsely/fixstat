import Foundation
import Testing
@testable import FixStatCore

/// Synthetic recordings: room noise, then the left tones and the right tones.
@Suite struct LoopbackAnalysisTests {
    static let rate = 48_000.0

    static func recording(left: Float, right: Float, rightHarmonics: Float = 0) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        func noise() -> Float { Float.random(in: -0.002...0.002, using: &generator) }
        var samples = (0..<Int(0.6 * rate)).map { _ in noise() }
        let tone = Int(SpeakerLoopback.toneSeconds * rate)
        for (frequencies, gain, harmonics) in [(SpeakerLoopback.leftFrequencies, left, Float(0)),
                                               (SpeakerLoopback.rightFrequencies, right, rightHarmonics)] {
            for f in frequencies {
                let fade = Int(0.02 * rate)
                for i in 0..<tone {
                    let t = Double(i) / rate
                    let envelope = Float(min(1, Double(i) / Double(fade), Double(tone - i) / Double(fade)))
                    let fundamental = Float(sin(2 * .pi * f * t))
                    let h = Float(sin(2 * .pi * 2 * f * t) + sin(2 * .pi * 3 * f * t))
                    samples.append(gain * envelope * (fundamental + harmonics * h) + noise())
                }
            }
        }
        return samples + (0..<Int(0.3 * rate)).map { _ in noise() }
    }

    @Test func bothSpeakersHeard() {
        let r = LoopbackResult.analyze(Self.recording(left: 0.2, right: 0.2), sampleRate: Self.rate, leadSeconds: 0.6)
        #expect(r.leftLevel > 30 && r.rightLevel > 30)
        #expect(r.findings.isEmpty)
    }

    @Test func aSilentSpeaker() {
        let r = LoopbackResult.analyze(Self.recording(left: 0.2, right: 0), sampleRate: Self.rate, leadSeconds: 0.6)
        #expect(r.findings.contains(.silent(left: false)))
        #expect(!r.findings.contains(.silent(left: true)))
    }

    @Test func aQuieterSpeaker() {
        let r = LoopbackResult.analyze(Self.recording(left: 0.2, right: 0.01), sampleRate: Self.rate, leadSeconds: 0.6)
        #expect(r.findings.contains { if case .quieter(left: false, _) = $0 { true } else { false } })
    }

    @Test func aDistortingSpeaker() {
        let r = LoopbackResult.analyze(Self.recording(left: 0.2, right: 0.2, rightHarmonics: 0.4), sampleRate: Self.rate, leadSeconds: 0.6)
        #expect(r.findings.contains { if case .distorted(left: false, _) = $0 { true } else { false } })
        #expect(!r.findings.contains { if case .distorted(left: true, _) = $0 { true } else { false } })
    }
}

@Suite struct PixelDefectTests {
    static func frame(_ value: UInt8, width: Int = 64, height: Int = 48, set: [(Int, Int, UInt8)] = []) -> LumaFrame {
        var values = [UInt8](repeating: value, count: width * height)
        for (x, y, v) in set { values[y * width + x] = v }
        return LumaFrame(width: width, height: height, values: values)
    }

    @Test func hotPixelsInTheDark() {
        var d = PixelDefects()
        d.analyzeDark(Self.frame(8, set: [(10, 10, 200), (30, 20, 180)]))
        #expect(d.darkValid && d.hotPixels == 2)
        #expect(d.problem)
    }

    @Test func deadPixelsAndDustOnABrightSurface() {
        var d = PixelDefects()
        let dust = (20...23).flatMap { x in (20...22).map { y in (x, y, UInt8(40)) } }
        d.analyzeBright(Self.frame(180, set: [(5, 5, 10)] + dust))
        #expect(d.brightValid && d.deadPixels == 1 && d.dustSpots == 1)
    }

    @Test func aBadColumn() {
        var d = PixelDefects()
        d.analyzeBright(Self.frame(180, set: (0..<48).map { (32, $0, UInt8(60)) }))
        #expect(d.badLines == 1)
    }

    @Test func notDarkOrBrightEnoughIsNotJudged() {
        var d = PixelDefects()
        d.analyzeDark(Self.frame(120, set: [(1, 1, 255)]))
        d.analyzeBright(Self.frame(40))
        #expect(!d.darkValid && !d.brightValid && !d.problem)
    }

    @Test func cleanFrames() {
        var d = PixelDefects()
        d.analyzeDark(Self.frame(6))
        d.analyzeBright(Self.frame(170))
        #expect(!d.problem && d.dustSpots == 0)
    }
}
