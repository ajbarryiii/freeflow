import Foundation

/// The power log's serialized owner (ARCHITECTURE.md, "Power log" → "When" and "Diagnostics"): one
/// consistent disk-plus-buffer snapshot, Clear generations, bounded buffering after write failures and
/// immutable export copies. All samples are invented.
enum PowerLogStoreTests {
    static var tests: [TestCase] {
        [
            ("snapshotsNeverDoubleCount", testSnapshotsNeverDoubleCount),
            ("clearWinsOverReadsInFlight", testClearWinsOverReadsInFlight),
            ("writeFailuresKeepTheNewestRowsUpToACap", testWriteFailuresKeepTheNewestRowsUpToACap),
            ("exportsAreFlushedImmutableCopies", testExportsAreFlushedImmutableCopies),
            ("exportsIncludeTheRotatedFile", testExportsIncludeTheRotatedFile),
            ("leftoverExportsAreRemoved", testLeftoverExportsAreRemoved),
        ]
    }

    private static func makeStore(_ directory: URL, limitBytes: Int = PowerLogRotation.limitBytes,
                                  maxBuffered: Int = 2_000) -> (PowerLogStore, PowerLogFiles) {
        let files = PowerLogFiles(directory: directory.appendingPathComponent("PowerLog", isDirectory: true),
                                  fileName: "log.csv", rotatedFileName: "log.1.csv", limitBytes: limitBytes)
        return (PowerLogStore(files: files, maxBufferedSamples: maxBuffered), files)
    }

    private static func snapshot(_ store: PowerLogStore) -> PowerLogStore.Snapshot {
        let box = ResultBox<PowerLogStore.Snapshot>()
        store.snapshot { box.set($0) }
        return box.wait()
    }

    private static func samples(_ range: Range<Int>) -> [PowerSample] {
        range.map { PowerSynthetic.sample(Double($0) * 60) }
    }

    /// Rows move from the buffer to disk inside the owner, so a snapshot sees each row exactly once.
    private static func testSnapshotsNeverDoubleCount() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, files) = makeStore(directory)
        for sample in samples(0 ..< 3) { store.append(sample) }
        var current = snapshot(store)
        TestSupport.expectEqual(current.samples, samples(0 ..< 3))
        TestSupport.expectEqual(current.bytesOnDisk, 0)

        store.flush()
        current = snapshot(store)
        TestSupport.expectEqual(current.samples, samples(0 ..< 3))
        TestSupport.expect(current.bytesOnDisk > 0 && current.fileCount == 1, "written")

        // Requests interleaved with flushes and appends, answered in order.
        let boxes = (0 ..< 4).map { _ in ResultBox<PowerLogStore.Snapshot>() }
        store.append(samples(3 ..< 4)[0])
        store.snapshot { boxes[0].set($0) }
        store.flush()
        store.snapshot { boxes[1].set($0) }
        store.append(samples(4 ..< 5)[0])
        store.snapshot { boxes[2].set($0) }
        store.flush()
        store.snapshot { boxes[3].set($0) }
        TestSupport.expectEqual(boxes.map { $0.wait().samples.count }, [4, 4, 5, 5])
        TestSupport.expectEqual(boxes[3].wait().samples, samples(0 ..< 5))
        TestSupport.expectEqual(files.readSamples(), samples(0 ..< 5))
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
    }

    /// A snapshot requested before a Clear is stale whenever it arrives; the Clear empties buffer and disk.
    private static func testClearWinsOverReadsInFlight() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, files) = makeStore(directory)
        for sample in samples(0 ..< 3) { store.append(sample) }
        store.flush()
        store.append(samples(3 ..< 4)[0])
        let before = ResultBox<PowerLogStore.Snapshot>()
        store.snapshot { before.set($0) }
        store.clear()
        let old = before.wait()
        TestSupport.expect(!store.isCurrent(old), "a read begun before Clear is discarded")
        let after = snapshot(store)
        TestSupport.expect(store.isCurrent(after), "a read begun after Clear is current")
        TestSupport.expectEqual(after.samples, [])
        TestSupport.expectEqual(after.bytesOnDisk, 0)
        TestSupport.expectEqual(files.existingFiles, [])
        store.flush()   // nothing buffered survives the Clear
        TestSupport.expectEqual(snapshot(store).samples, [])
    }

    /// While writes fail, the buffer keeps only the newest rows; the next successful flush writes them.
    private static func testWriteFailuresKeepTheNewestRowsUpToACap() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("PowerLog")
        try! Data().write(to: blocker)   // a file where the log directory belongs: every write fails
        let (store, files) = makeStore(directory, maxBuffered: 4)
        for (index, sample) in samples(0 ..< 10).enumerated() {
            store.append(sample)
            if index % 3 == 0 { store.flush() }
        }
        store.flush()
        var current = snapshot(store)
        TestSupport.expectEqual(current.samples, samples(6 ..< 10))
        TestSupport.expectEqual(current.droppedSamples, 6)
        TestSupport.expectEqual(current.bytesOnDisk, 0)

        try! FileManager.default.removeItem(at: blocker)
        store.flush()
        current = snapshot(store)
        TestSupport.expectEqual(files.readSamples(), samples(6 ..< 10))
        TestSupport.expectEqual(current.samples, samples(6 ..< 10))
        TestSupport.expect(current.bytesOnDisk > 0, "written once the directory can be created")
    }

    /// Export flushes first, then copies into a fresh directory; later appends never change the copies.
    private static func testExportsAreFlushedImmutableCopies() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, files) = makeStore(directory)
        let exports = directory.appendingPathComponent("Exports", isDirectory: true)
        for sample in samples(0 ..< 2) { store.append(sample) }   // buffered only
        let box = ResultBox<PowerLogStore.Export?>()
        store.exportSnapshot(into: exports) { box.set($0) }
        guard let export = box.wait() else { return TestSupport.expect(false, "an export") }
        TestSupport.expectEqual(export.files.map(\.lastPathComponent), ["log.csv"])
        TestSupport.expect(export.directory.deletingLastPathComponent().standardizedFileURL.path == exports.standardizedFileURL.path,
                           "a fresh directory under the exports directory")
        TestSupport.expect(export.files.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == export.directory.standardizedFileURL.path }, "inside it")
        TestSupport.expectEqual(files.readSamples(), samples(0 ..< 2))   // flushed
        let copied = try! Data(contentsOf: export.files[0])
        TestSupport.expectEqual(PowerLogCSV.parse(String(decoding: copied, as: UTF8.self)), samples(0 ..< 2))
        for url in [export.directory] + export.files {
            let excluded = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            TestSupport.expect(excluded == true, "\(url.lastPathComponent) is excluded from backup")
        }

        for sample in samples(2 ..< 5) { store.append(sample) }
        store.flush()
        store.clear()
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
        TestSupport.expectEqual(try! Data(contentsOf: export.files[0]), copied)   // immutable

        store.removeExport(export)
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
        TestSupport.expect(!FileManager.default.fileExists(atPath: export.directory.path), "removed after sharing")

        let empty = ResultBox<PowerLogStore.Export?>()
        store.exportSnapshot(into: exports) { empty.set($0) }
        TestSupport.expect(empty.wait() == nil, "nothing to export after Clear")
    }

    private static func testExportsIncludeTheRotatedFile() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, files) = makeStore(directory, limitBytes: 400)
        store.append(samples(0 ..< 1)[0])
        store.flush()
        store.append(samples(1 ..< 2)[0])
        store.flush()   // past 400 bytes: rotates
        let box = ResultBox<PowerLogStore.Export?>()
        store.exportSnapshot(into: directory.appendingPathComponent("Exports")) { box.set($0) }
        guard let export = box.wait() else { return TestSupport.expect(false, "an export") }
        TestSupport.expectEqual(files.existingFiles.count, 2)
        TestSupport.expectEqual(export.files.map(\.lastPathComponent), ["log.1.csv", "log.csv"])   // oldest first
        let exported = export.files.flatMap { PowerLogCSV.parse(String(decoding: try! Data(contentsOf: $0), as: UTF8.self)) }
        TestSupport.expectEqual(exported, samples(0 ..< 2))
    }

    /// Copies left by an app that died with the share sheet open are removed at the next launch.
    private static func testLeftoverExportsAreRemoved() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = makeStore(directory)
        let exports = directory.appendingPathComponent("Exports", isDirectory: true)
        store.append(samples(0 ..< 1)[0])
        let box = ResultBox<PowerLogStore.Export?>()
        store.exportSnapshot(into: exports) { box.set($0) }
        TestSupport.expect(box.wait() != nil, "an export")
        store.removeExports(in: exports)
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
        TestSupport.expect(!FileManager.default.fileExists(atPath: exports.path), "leftovers removed")
        store.removeExports(in: exports)   // nothing to remove is fine
        TestSupport.expect(store.waitUntilIdle(timeout: 5), "idle")
    }
}

/// A value delivered once from another thread.
private final class ResultBox<Value>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Value?

    func set(_ value: Value) {
        self.value = value
        semaphore.signal()
    }

    func wait() -> Value {
        if semaphore.wait(timeout: .now() + 10) == .timedOut { fatalError("no result within 10 s") }
        semaphore.signal()   // later waits return at once
        return value!
    }
}
