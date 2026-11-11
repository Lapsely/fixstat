import Foundation
import Testing
@testable import MacSensors
import FixStatCore

@Suite struct CapacityCheckTests {
    @Test func aRealRunOnATemporaryFolder() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fixstat-capacity-test-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = CapacityCheck().run(directory: folder, limit: 64 << 20) { _ in }
        #expect(result.writtenBytes == 64 << 20)
        #expect(result.verifiedBytes == result.writtenBytes)
        #expect(result.passed && result.realBytes == nil)
        // The test files are gone.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func aFakeDriveHoldsWhatReadBackBeforeTheFirstError() {
        let r = CapacityCheck.Result(startedAt: Date(), volumeBytes: 64_000_000_000, freeBytes: 63_000_000_000,
                                     writtenBytes: 62_000_000_000, verifiedBytes: 62_000_000_000,
                                     goodBytesBeforeError: 7_000_000_000, badChunks: 6_500, ioErrors: 0, stoppedEarly: false)
        #expect(!r.passed)
        #expect(r.realBytes == 8_000_000_000)
        #expect(CapacityCheckText.verdict(r).1)
    }
}
