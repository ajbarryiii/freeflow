import Foundation

/// The power log's one serialized owner (test builds only; ARCHITECTURE.md, "Power log"). Buffering,
/// encoding, rotation, writes, reads for the summary, export copies and Clear all run in order on one
/// utility queue, never on the caller's thread:
///
/// - A snapshot sees disk plus buffer at one point in that order, so no row is counted twice.
/// - A snapshot carries the Clear generation current when it was requested; `isCurrent` is false once a
///   later Clear was requested, so a read already in flight never brings cleared data back.
/// - After a failed write the rows stay buffered for the next flush, but only the newest
///   `maxBufferedSamples`; older rows are dropped and counted.
/// - An export flushes, then copies the files into a fresh directory that nothing writes again.
final class PowerLogStore: @unchecked Sendable {
    struct Snapshot: Sendable {
        /// Disk (oldest file first), then the buffer.
        var samples: [PowerSample]
        var bytesOnDisk: Int
        var fileCount: Int
        /// Rows dropped since launch because writes kept failing.
        var droppedSamples: Int
        var generation: UInt64
    }

    /// Immutable copies of the log for the share sheet. Remove them when sharing completes.
    struct Export: Sendable, Equatable {
        var directory: URL
        /// Oldest first.
        var files: [URL]
    }

    let maxBufferedSamples: Int

    private let files: PowerLogFiles
    private let queue = DispatchQueue(label: "LocalFlow.PowerLogStore", qos: .utility)
    private let lock = NSLock()
    private var clearGeneration: UInt64 = 0
    // Owned by `queue`.
    private var buffer: [PowerSample] = []
    private var dropped = 0

    init(files: PowerLogFiles, maxBufferedSamples: Int = 2_000) {
        self.files = files
        self.maxBufferedSamples = maxBufferedSamples
    }

    func append(_ sample: PowerSample) {
        queue.async {
            self.buffer.append(sample)
            self.trimBuffer()
        }
    }

    /// Writes the buffer. On failure it stays buffered (bounded) until the next flush.
    func flush() {
        queue.async { self.writeBuffer() }
    }

    /// `completion` runs on the owner's queue, so heavy work there (a summary) stays off the main thread.
    func snapshot(_ completion: @escaping @Sendable (Snapshot) -> Void) {
        let generation = currentGeneration
        queue.async {
            let samples = self.files.readSamples() + self.buffer
            completion(Snapshot(samples: samples, bytesOnDisk: self.files.totalBytes, fileCount: self.files.existingFiles.count,
                                droppedSamples: self.dropped, generation: generation))
        }
    }

    /// False once a Clear was requested after the snapshot was.
    func isCurrent(_ snapshot: Snapshot) -> Bool { isCurrent(generation: snapshot.generation) }

    func isCurrent(generation: UInt64) -> Bool { generation == currentGeneration }

    func clear() {
        lock.lock()
        clearGeneration += 1
        lock.unlock()
        queue.async {
            self.buffer.removeAll()
            self.dropped = 0
            try? self.files.clear()
        }
    }

    /// Flushes, then copies the log files into a new directory under `directory`, excluded from backup.
    /// `completion` gets nil when there is nothing to export or the copy failed.
    func exportSnapshot(into directory: URL, completion: @escaping @Sendable (Export?) -> Void) {
        queue.async {
            self.writeBuffer()
            completion(self.copyFiles(into: directory))
        }
    }

    func removeExport(_ export: Export) {
        queue.async { try? FileManager.default.removeItem(at: export.directory) }
    }

    /// Removes every export left under `directory`, for example by an app that died while sharing.
    func removeExports(in directory: URL) {
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Waits up to `timeout` for the work queued so far, for termination. True when it finished.
    @discardableResult
    func waitUntilIdle(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    // MARK: Private (on `queue`)

    private var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return clearGeneration
    }

    private func trimBuffer() {
        let excess = buffer.count - maxBufferedSamples
        guard excess > 0 else { return }
        buffer.removeFirst(excess)
        dropped += excess
    }

    private func writeBuffer() {
        guard !buffer.isEmpty else { return }
        do {
            try files.append(buffer)
            buffer.removeAll()
        } catch {
            trimBuffer()
        }
    }

    private func copyFiles(into directory: URL) -> Export? {
        let sources = files.existingFiles
        guard !sources.isEmpty else { return nil }
        let fileManager = FileManager.default
        let target = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try Self.excludeFromBackup(directory)
            try Self.excludeFromBackup(target)
            var copies: [URL] = []
            for source in sources {
                let copy = target.appendingPathComponent(source.lastPathComponent, isDirectory: false)
                try fileManager.copyItem(at: source, to: copy)
                try Self.excludeFromBackup(copy)
                copies.append(copy)
            }
            return Export(directory: target, files: copies)
        } catch {
            try? fileManager.removeItem(at: target)
            return nil
        }
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
