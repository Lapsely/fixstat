import Foundation
import MacSensors

/// Runs the real-capacity check on a volume in the background; progress on the main thread through
/// `onChange`. Results are kept per volume for the session (and the report).
public final class CapacityCheckRunner: @unchecked Sendable {
    public enum State: Equatable { case idle, running, finished }

    public private(set) var state = State.idle
    public private(set) var phase = CapacityCheck.Phase.write
    public private(set) var fraction = 0.0
    public private(set) var throughput = 0.0
    public private(set) var volume: String?
    public private(set) var results: [String: CapacityCheck.Result] = [:]
    public var onChange: (() -> Void)?

    private var check: CapacityCheck?
    private var activity: NSObjectProtocol?

    public init() {}

    /// The volume has room for at least one chunk beyond the reserve.
    public static func hasSpace(_ volume: USBVolume) -> Bool {
        volume.availableBytes > CapacityCheck.reserveBytes + Int64(CapacityCheck.chunkSize)
    }

    /// Rough duration at `megabytesPerSecond` (write and read back).
    public static func estimate(_ volume: USBVolume, megabytesPerSecond: Double = 30) -> TimeInterval {
        Double(max(0, volume.availableBytes - CapacityCheck.reserveBytes)) / 1e6 / megabytesPerSecond * 2
    }

    public func start(_ volume: USBVolume) {
        guard state != .running else { return }
        let check = CapacityCheck()
        self.check = check
        state = .running
        phase = .write
        fraction = 0
        self.volume = volume.name
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Drive capacity check")
        onChange?()
        let url = volume.url, name = volume.name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let throttle = ProgressThrottle()
            let result = check.run(directory: url) { progress in
                guard throttle.due() else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.phase = progress.phase
                    self.fraction = progress.total > 0 ? Double(progress.bytes) / Double(progress.total) : 0
                    self.throughput = progress.throughput
                    self.onChange?()
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.results[name] = result
                self.state = .finished
                if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity) }
                self.activity = nil
                self.check = nil
                self.onChange?()
            }
        }
    }

    public func stop() { check?.cancel() }
}

/// Lets a progress update through at most twice a second (called from the test's thread).
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func due() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Date().timeIntervalSince(last) > 0.5 else { return false }
        last = Date()
        return true
    }
}

/// Texts of the capacity check (both SSD windows).
public enum CapacityCheckText {
    public static var explanation: String {
        L("Real capacity: fills the free space of a USB stick, card or external drive with test data, reads it all back and compares it. A fake drive that reports more than it holds loses data past its real size. The drive's files are not touched and the test data is deleted afterwards; a large drive takes long (both ways at its own speed).")
    }

    public static func estimate(_ seconds: TimeInterval) -> String {
        L("about %@", Format.duration(seconds))
    }

    public static func progress(_ runner: CapacityCheckRunner) -> String {
        let phase = runner.phase == .write ? L("Writing…") : L("Reading and verifying…")
        return phase + " " + Format.percent(runner.fraction * 100) + " · " + Format.number(runner.throughput) + " MB/s"
    }

    public static func rows(_ r: CapacityCheck.Result) -> [(String, String)] {
        var rows = [(L("Size reported"), Format.bytes(Double(r.volumeBytes))),
                    (L("Tested"), L("%1$@ of %2$@ free", Format.bytes(Double(r.verifiedBytes)), Format.bytes(Double(r.freeBytes))))]
        if let w = r.writeSpeed, let rd = r.readSpeed {
            rows.append((L("Speed"), L("write %1$@ · read %2$@", Format.number(w) + " MB/s", Format.number(rd) + " MB/s")))
        }
        return rows
    }

    /// The verdict: (text, problem).
    public static func verdict(_ r: CapacityCheck.Result) -> (String, Bool) {
        if let real = r.realBytes {
            return (L("Data read back wrong after %1$@: the drive holds about %2$@ of the %3$@ it reports (fake capacity, or failing memory).",
                      Format.bytes(Double(r.goodBytesBeforeError ?? 0)), Format.bytes(Double(real)), Format.bytes(Double(r.volumeBytes))), true)
        }
        if r.stoppedEarly { return (L("Stopped before the end: only the part tested counts."), false) }
        if r.writtenBytes == 0 { return (L("Not enough free space to test."), false) }
        return (L("All %@ read back intact: the drive holds what it reports.", Format.bytes(Double(r.verifiedBytes))), false)
    }
}
