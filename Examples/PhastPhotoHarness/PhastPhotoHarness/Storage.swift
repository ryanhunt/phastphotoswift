import Foundation

/// Where the harness keeps its files. Everything is in the app's Documents folder, which Files ("On My iPhone")
/// and Finder (the device's Files tab) can open, so raw scans and results can be copied to a Mac.
///
///     Documents/Raw/<stamp>/       untouched scans as they arrived (RawSpool), for `phastphoto process`
///     Documents/Processed/         pipeline output for real scans (+ Enhanced/, duplicate cache)
///     Documents/Samples/           pipeline output for synthetic samples
///     Documents/timings.csv        one line per print: time and memory
///     Documents/harness-log.txt    the on-screen log
enum Storage {
    static var documents: URL { URL.documentsDirectory }
    static var processed: URL { documents.appending(path: "Processed", directoryHint: .isDirectory) }
    static var samples: URL { documents.appending(path: "Samples", directoryHint: .isDirectory) }
    static var logFile: URL { documents.appending(path: "harness-log.txt") }
    static var timingsFile: URL { documents.appending(path: "timings.csv") }

    static func raw(_ name: String) -> URL {
        documents.appending(path: "Raw", directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory)
    }

    /// `yyyyMMdd-HHmmss`, the same stamp RawSpool puts on file names.
    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Appends a line to a text file, creating it (with `header` first) if needed.
    static func append(_ line: String, to url: URL, header: String? = nil) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            let start = header.map { Data(($0 + "\n").utf8) } ?? Data()
            try? (start + data).write(to: url, options: .atomic)
        }
    }

    /// Removes everything the harness wrote.
    static func deleteAll() throws {
        let fm = FileManager.default
        for url in try fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) {
            try fm.removeItem(at: url)
        }
    }
}
