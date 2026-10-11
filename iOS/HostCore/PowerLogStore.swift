import Foundation

/// The power log's one serialized owner (test builds only; ARCHITECTURE.md, "Power log"). Buffering,
/// encoding, rotation, writes, reads for the summary, export copies and Clear all run in order on one
/// utility queue, never on the caller's thread:
///
/// - A snapshot sees disk plus buffer at one point in that order, so no row is counted twice. An append
///   is all or nothing (`PowerLogFiles`); if one cannot even be undone, its rows are dropped and counted
///   rather than kept for a retry that would write them twice.
/// - Each snapshot carries the generation it was read at. A successful Clear advances the generation, and
///   `isCurrent` is false while a Clear is pending, so a read already in flight never brings cleared data
///   back. A failed Clear reports `false`, keeps the log, and leaves the generation alone.
/// - After a failed write the rows stay buffered for the next flush, but only the newest
///   `maxBufferedSamples`; older rows are dropped and counted.
/// - An export flushes, then copies the files into a fresh directory that nothing writes again. Rows that
///   could not be flushed are added to the copy, so an export is complete or refused.
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

    enum ExportOutcome: Sendable, Equatable {
        case exported(Export)
        /// Nothing logged yet.
        case empty
        /// The copies could not be written; nothing partial is left behind.
        case failed
    }

    let maxBufferedSamples: Int

    private let files: PowerLogFiles
    private let queue = DispatchQueue(label: "LocalFlow.PowerLogStore", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var generation: UInt64 = 0
    private var requestedClears = 0
    private var finishedClears = 0
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
        queue.async {
            let samples = self.files.readSamples() + self.buffer
            completion(Snapshot(samples: samples, bytesOnDisk: self.files.totalBytes, fileCount: self.files.existingFiles.count,
                                droppedSamples: self.dropped, generation: self.locked { self.generation }))
        }
    }

    /// False while a Clear is pending, and once a Clear succeeded after the snapshot was read.
    func isCurrent(_ snapshot: Snapshot) -> Bool { isCurrent(generation: snapshot.generation) }

    func isCurrent(generation: UInt64) -> Bool {
        locked { requestedClears == finishedClears && generation == self.generation }
    }

    /// Deletes the log and the buffer. `completion` (on the owner's queue) gets false when the files could
    /// not be deleted; then the log, the buffer and the generation are kept.
    func clear(completion: (@Sendable (Bool) -> Void)? = nil) {
        locked { requestedClears += 1 }
        queue.async {
            let cleared = (try? self.files.clear()) != nil
            if cleared {
                self.buffer.removeAll()
                self.dropped = 0
            }
            self.locked {
                if cleared { self.generation += 1 }
                self.finishedClears += 1
            }
            completion?(cleared)
        }
    }

    /// Flushes, then copies the log into a new directory under `directory`, excluded from backup. Rows
    /// that could not be flushed are appended to the copy, so it holds exactly disk plus buffer.
    func exportSnapshot(into directory: URL, completion: @escaping @Sendable (ExportOutcome) -> Void) {
        queue.async {
            self.writeBuffer()
            completion(self.copy(into: directory))
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

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
        } catch let failure as PowerLogAppendFailure where !failure.rolledBack {
            // Some rows may be on disk: never write them again.
            dropped += buffer.count
            buffer.removeAll()
        } catch {
            trimBuffer()
        }
    }

    private func copy(into directory: URL) -> ExportOutcome {
        let sources = files.existingFiles
        guard !sources.isEmpty || !buffer.isEmpty else { return .empty }
        let fileManager = FileManager.default
        let target = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try PowerLogFiles.Operations.standard.excludeFromBackup(directory)
            try PowerLogFiles.Operations.standard.excludeFromBackup(target)
            for source in sources {
                let copy = target.appendingPathComponent(source.lastPathComponent, isDirectory: false)
                try fileManager.copyItem(at: source, to: copy)
                try PowerLogFiles.Operations.standard.excludeFromBackup(copy)
            }
            let copies = PowerLogFiles(directory: target, fileName: files.currentURL.lastPathComponent,
                                       rotatedFileName: files.rotatedURL.lastPathComponent, limitBytes: .max)
            try copies.append(buffer)
            return .exported(Export(directory: target, files: copies.existingFiles))
        } catch {
            try? fileManager.removeItem(at: target)
            return .failed
        }
    }
}
