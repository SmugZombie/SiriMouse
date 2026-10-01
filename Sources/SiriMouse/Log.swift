import Foundation

/// Size-bounded diagnostic log at ~/Library/Logs/SiriMouse/SiriMouse.log.
/// Unmapped HID usages are written here, which is how new remote buttons get identified.
enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SiriMouse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SiriMouse.log")
    }()

    private static let queue = DispatchQueue(label: "SiriMouse.log", qos: .utility)
    private static let maxBytes: UInt64 = 1_000_000
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxBytes {
                let rotated = url.appendingPathExtension("1")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: url, to: rotated)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// Only written when "Verbose Logging" is on, because touch and button traffic is chatty.
    static func debug(_ message: @autoclosure () -> String) {
        if Settings.shared.verboseLogging { info(message()) }
    }
}
