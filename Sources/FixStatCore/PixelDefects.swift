import Foundation

/// Camera sensor defects from two averaged luma frames: the lens covered (dark) and a plain bright
/// surface (bright). Hot pixels stay bright in the dark, dead pixels stay dark on the bright surface,
/// and a row or column that differs from its neighbours along most of its length points to the
/// sensor or its cable. The camera's own image processing hides single faulty pixels, so what
/// remains visible here is a real fault. Dust on the lens shows as soft dark spots (several pixels),
/// counted apart from dead pixels.
public struct PixelDefects: Equatable, Sendable {
    public var hotPixels = 0
    public var deadPixels = 0
    public var dustSpots = 0
    public var badLines = 0
    /// Mean luma of the dark and bright frames (0 … 255): the dark one must really be dark, the
    /// bright one bright, or the step is not judged.
    public var darkMean: Double?
    public var brightMean: Double?

    /// The covered frame must be this dark and the bright one this bright.
    public static let darkLimit = 24.0
    public static let brightLimit = 90.0

    public var darkValid: Bool { (darkMean ?? 255) <= Self.darkLimit }
    public var brightValid: Bool { (brightMean ?? 0) >= Self.brightLimit }
    public var problem: Bool { hotPixels > 0 || deadPixels > 0 || badLines > 0 }

    public init() {}

    /// A pixel this far above the frame's level in the dark is hot.
    static let hotMargin = 60
    /// A pixel below this share of its neighbourhood on the bright surface is dead.
    static let deadShare = 0.45

    public mutating func analyzeDark(_ frame: LumaFrame) {
        let values = frame.values
        darkMean = values.isEmpty ? nil : Double(values.reduce(0) { $0 + Int($1) }) / Double(values.count)
        guard darkValid, let mean = darkMean else { hotPixels = 0; return }
        let limit = Int(mean) + Self.hotMargin
        hotPixels = values.reduce(0) { $0 + (Int($1) > limit ? 1 : 0) }
        badLines = max(badLines, Self.lines(frame, bright: false))
    }

    public mutating func analyzeBright(_ frame: LumaFrame) {
        let values = frame.values
        brightMean = values.isEmpty ? nil : Double(values.reduce(0) { $0 + Int($1) }) / Double(values.count)
        guard brightValid else { deadPixels = 0; dustSpots = 0; return }
        // Local level: the mean of 16 × 16 blocks (the image is not evenly lit, vignetting).
        let w = frame.width, h = frame.height, block = 16
        let bw = (w + block - 1) / block, bh = (h + block - 1) / block
        var blockMean = [Double](repeating: 0, count: bw * bh)
        var blockCount = [Int](repeating: 0, count: bw * bh)
        for y in 0..<h { for x in 0..<w {
            let b = (y / block) * bw + x / block
            blockMean[b] += Double(values[y * w + x])
            blockCount[b] += 1
        } }
        for b in blockMean.indices where blockCount[b] > 0 { blockMean[b] /= Double(blockCount[b]) }
        var dark = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let level = blockMean[(y / block) * bw + x / block]
            dark[y * w + x] = Double(values[y * w + x]) < level * Self.deadShare
        } }
        // Single dark pixels are dead; groups of several are dust (or a smudge) on the lens.
        var dead = 0, dust = 0
        var seen = [Bool](repeating: false, count: w * h)
        for start in dark.indices where dark[start] && !seen[start] {
            var stack = [start], size = 0
            seen[start] = true
            while let p = stack.popLast() {
                size += 1
                let x = p % w, y = p / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let q = ny * w + nx
                    if dark[q] && !seen[q] { seen[q] = true; stack.append(q) }
                }
            }
            if size <= 2 { dead += size } else { dust += 1 }
        }
        deadPixels = dead
        dustSpots = dust
        badLines = max(badLines, Self.lines(frame, bright: true))
    }

    /// Rows or columns whose mean differs from both neighbours by more than `lineMargin`.
    static let lineMargin = 25.0

    static func lines(_ frame: LumaFrame, bright: Bool) -> Int {
        let w = frame.width, h = frame.height, v = frame.values
        guard w > 2, h > 2 else { return 0 }
        var rows = [Double](repeating: 0, count: h), columns = [Double](repeating: 0, count: w)
        for y in 0..<h { for x in 0..<w {
            let value = Double(v[y * w + x])
            rows[y] += value
            columns[x] += value
        } }
        rows = rows.map { $0 / Double(w) }
        columns = columns.map { $0 / Double(h) }
        func odd(_ m: [Double]) -> Int {
            (1..<(m.count - 1)).filter { i in
                abs(m[i] - m[i - 1]) > lineMargin && abs(m[i] - m[i + 1]) > lineMargin
            }.count
        }
        return odd(rows) + odd(columns)
    }
}

/// Texts of the camera pixel test (both interfaces).
public enum PixelText {
    public static var explanation: String {
        L("Pixel test: cover the lens completely (a finger or tape) and measure, then fill the picture with a plain bright surface (white paper, a white wall) and measure. Hot pixels stay bright in the dark, dead pixels dark on the bright surface; a bright or dark line points to the sensor or its cable.")
    }

    public static func rows(_ d: PixelDefects) -> [(String, String)] {
        var rows: [(String, String)] = []
        if d.darkMean != nil {
            rows.append((L("Lens covered"), d.darkValid ? L("%lld hot pixels", d.hotPixels)
                         : L("not dark enough: cover the lens completely")))
        }
        if d.brightMean != nil {
            rows.append((L("Bright surface"), d.brightValid ? L("%1$lld dead pixels · %2$lld spots (dust or smudge on the lens)", d.deadPixels, d.dustSpots)
                         : L("not bright enough: use a brighter, plain surface")))
        }
        if d.darkMean != nil || d.brightMean != nil { rows.append((L("Line defects"), Format.number(Double(d.badLines)))) }
        return rows
    }

    public static func findings(_ d: PixelDefects) -> [String] {
        var out: [String] = []
        if d.hotPixels > 0 { out.append(L("%lld hot pixels: the camera sensor is faulty.", d.hotPixels)) }
        if d.deadPixels > 0 { out.append(L("%lld dead pixels: the camera sensor is faulty (or a speck on the lens).", d.deadPixels)) }
        if d.badLines > 0 { out.append(L("%lld lines differ from their neighbours: the camera sensor or its cable.", d.badLines)) }
        if d.dustSpots > 0, d.deadPixels == 0 { out.append(L("Spots on the picture: clean the lens and the glass in front of it.")) }
        return out
    }

    public static func summary(_ d: PixelDefects) -> String {
        L("%1$lld hot, %2$lld dead pixels, %3$lld line defects", d.hotPixels, d.deadPixels, d.badLines)
    }
}
