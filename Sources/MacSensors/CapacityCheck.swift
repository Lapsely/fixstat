import Foundation

/// Real capacity of a drive (fake USB sticks and SSDs that report more than they hold): fills the
/// free space with 1 GiB files of a pattern derived from each chunk's position, then reads all of it
/// back (no cache) and compares, like H2testw / F3. A fake drive wraps its writes round and
/// overwrites what came first, or returns garbage past its real size, so the first chunk that reads
/// back wrong marks how much it really holds. Existing files are not touched; the test files are
/// deleted at the end. Files stay below 4 GiB for FAT32 sticks.
public final class CapacityCheck: @unchecked Sendable {
    public enum Phase: Sendable { case write, verify }

    public struct Progress: Sendable {
        public var phase: Phase
        public var bytes: Int64
        public var total: Int64
        /// MB/s of the last chunk.
        public var throughput: Double
    }

    public struct Result: Codable, Sendable, Equatable {
        public var startedAt: Date
        /// The volume's size as macOS reports it, its free space at the start, and what the test filled.
        public var volumeBytes: Int64
        public var freeBytes: Int64
        public var writtenBytes: Int64
        public var verifiedBytes: Int64
        /// Bytes that read back intact before the first bad chunk (nil: none bad).
        public var goodBytesBeforeError: Int64?
        public var badChunks: Int
        public var ioErrors: Int
        /// MB/s.
        public var writeSpeed: Double?
        public var readSpeed: Double?
        public var stoppedEarly: Bool

        /// Every written byte read back intact.
        public var passed: Bool { badChunks == 0 && ioErrors == 0 && !stoppedEarly && verifiedBytes >= writtenBytes && writtenBytes > 0 }

        /// What the drive really holds: the used space plus what read back intact.
        public var realBytes: Int64? {
            guard badChunks > 0 || ioErrors > 0, let good = goodBytesBeforeError else { return nil }
            return (volumeBytes - freeBytes) + good
        }
    }

    public static let chunkSize = 8 << 20
    public static let fileBytes: Int64 = 1 << 30
    /// Free space left on the drive.
    public static let reserveBytes: Int64 = 64 << 20

    private let lock = NSLock()
    private var cancelled = false
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public init() {}

    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    public static func space(of directory: URL) -> (total: Int64, free: Int64)? {
        guard let values = try? directory.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity else { return nil }
        return (Int64(total), Int64(free))
    }

    /// Runs synchronously; call from a background thread. `limit` caps the bytes (tests).
    public func run(directory: URL, limit: Int64? = nil, progress: @Sendable (Progress) -> Void) -> Result {
        let started = Date()
        let space = Self.space(of: directory) ?? (0, 0)
        let chunk = Self.chunkSize
        var target = max(0, space.free - Self.reserveBytes)
        if let limit { target = min(target, limit) }
        let chunks = Int(target / Int64(chunk))
        var result = Result(startedAt: started, volumeBytes: space.total, freeBytes: space.free, writtenBytes: 0,
                            verifiedBytes: 0, goodBytesBeforeError: nil, badChunks: 0, ioErrors: 0, stoppedEarly: false)
        let chunksPerFile = Int(Self.fileBytes / Int64(chunk))
        let folder = directory.appendingPathComponent(".fixstat-capacity-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ index: Int) -> String { folder.appendingPathComponent(String(format: "%04d.bin", index)).path }

        let seed = UInt64(started.timeIntervalSince1970 * 1000)
        var buffer = [UInt8](repeating: 0, count: chunk)
        var expected = [UInt8](repeating: 0, count: chunk)
        var writeSeconds = 0.0, written = 0

        // Fill.
        var fd: Int32 = -1
        for index in 0..<chunks {
            if isCancelled { break }
            if index % chunksPerFile == 0 {
                if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
                fd = open(file(index / chunksPerFile), O_CREAT | O_TRUNC | O_WRONLY, 0o600)
                guard fd >= 0 else { result.ioErrors += 1; break }
                _ = fcntl(fd, F_NOCACHE, 1)
            }
            SSDStressTest.fill(&buffer, seed: seed, chunk: index)
            let t0 = Date()
            let n = buffer.withUnsafeBytes { pwrite(fd, $0.baseAddress, chunk, off_t(index % chunksPerFile) * off_t(chunk)) }
            if index % 32 == 31 { fsync(fd) }
            writeSeconds += Date().timeIntervalSince(t0)
            guard n == chunk else {
                // Full sooner than macOS said (no error), or a failing drive.
                if !(n < 0 && errno == ENOSPC) { result.ioErrors += 1 }
                break
            }
            written += 1
            progress(Progress(phase: .write, bytes: Int64(written) * Int64(chunk), total: Int64(chunks) * Int64(chunk),
                              throughput: Double(chunk) / max(Date().timeIntervalSince(t0), 1e-6) / 1e6))
        }
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
        result.writtenBytes = Int64(written) * Int64(chunk)
        if written > 0, writeSeconds > 0 { result.writeSpeed = Double(result.writtenBytes) / writeSeconds / 1e6 }

        // Read back everything, without the cache.
        var readSeconds = 0.0, read = 0
        var current = -1
        for index in 0..<written {
            if isCancelled { break }
            if index / chunksPerFile != current {
                if fd >= 0 { close(fd) }
                current = index / chunksPerFile
                fd = open(file(current), O_RDONLY)
                guard fd >= 0 else { result.ioErrors += 1; break }
                _ = fcntl(fd, F_NOCACHE, 1)
            }
            let t0 = Date()
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunk, off_t(index % chunksPerFile) * off_t(chunk)) }
            readSeconds += Date().timeIntervalSince(t0)
            var bad = n != chunk
            if bad { result.ioErrors += 1 } else {
                SSDStressTest.fill(&expected, seed: seed, chunk: index)
                if buffer != expected { result.badChunks += 1; bad = true }
            }
            if bad, result.goodBytesBeforeError == nil { result.goodBytesBeforeError = Int64(index) * Int64(chunk) }
            read += 1
            progress(Progress(phase: .verify, bytes: Int64(read) * Int64(chunk), total: result.writtenBytes,
                              throughput: Double(chunk) / max(Date().timeIntervalSince(t0), 1e-6) / 1e6))
        }
        if fd >= 0 { close(fd) }
        result.verifiedBytes = Int64(read) * Int64(chunk)
        if read > 0, readSeconds > 0 { result.readSpeed = Double(result.verifiedBytes) / readSeconds / 1e6 }
        result.stoppedEarly = isCancelled
        return result
    }
}
