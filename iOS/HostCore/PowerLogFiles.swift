import Foundation

/// The power log on disk (test builds only): a current file and at most one rotated, older file in a
/// directory excluded from backup. The caller chooses the directory and names, so nothing outside the
/// `LOCALFLOW_POWER_LOG` gate names a power-log file. Not thread-safe; one owner calls it.
final class PowerLogFiles {
    let directory: URL
    let currentURL: URL
    let rotatedURL: URL
    let limitBytes: Int

    init(directory: URL, fileName: String, rotatedFileName: String, limitBytes: Int = PowerLogRotation.limitBytes) {
        self.directory = directory
        currentURL = directory.appendingPathComponent(fileName, isDirectory: false)
        rotatedURL = directory.appendingPathComponent(rotatedFileName, isDirectory: false)
        self.limitBytes = limitBytes
    }

    /// Oldest first.
    var existingFiles: [URL] {
        [rotatedURL, currentURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var totalBytes: Int { existingFiles.reduce(0) { $0 + size(of: $1) } }

    /// Appends rows. A new file starts with the header and schema line. The current file is rotated first
    /// when the rows would take it past `limitBytes`, or when it was written with another header.
    func append(_ samples: [PowerSample]) throws {
        guard !samples.isEmpty else { return }
        try ensureDirectory()
        let rows = Data(samples.map { PowerLogCSV.line($0) + "\n" }.joined().utf8)
        let existing = size(of: currentURL)
        if existing > 0, !startsWithPreamble(currentURL) ||
            PowerLogRotation.shouldRotate(existingBytes: existing, appendingBytes: rows.count, limit: limitBytes) {
            try rotate()
        }
        if size(of: currentURL) == 0 {
            try (Data(PowerLogCSV.preamble.utf8) + rows).write(to: currentURL, options: .atomic)
            try excludeFromBackup(currentURL)
        } else {
            let handle = try FileHandle(forWritingTo: currentURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: rows)
        }
    }

    /// Every readable sample, oldest file first.
    func readSamples() -> [PowerSample] {
        existingFiles.flatMap { url -> [PowerSample] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return PowerLogCSV.parse(String(decoding: data, as: UTF8.self))
        }
    }

    func clear() throws {
        for url in existingFiles { try FileManager.default.removeItem(at: url) }
    }

    // MARK: Private

    private func rotate() throws {
        if FileManager.default.fileExists(atPath: rotatedURL.path) { try FileManager.default.removeItem(at: rotatedURL) }
        try FileManager.default.moveItem(at: currentURL, to: rotatedURL)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup(directory)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func startsWithPreamble(_ url: URL) -> Bool {
        let preamble = Data(PowerLogCSV.preamble.utf8)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: preamble.count)) == preamble
    }
}
