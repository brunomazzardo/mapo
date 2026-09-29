import AppKit

/// What a file is, from its extension, size and first bytes (R-ED-6, R-FS-6).
public enum FileKind: Equatable, Sendable {
    /// Editable text.
    case text
    /// Text over 8 MB: shown read-only.
    case largeText
    /// A NUL byte in the first 8 KiB.
    case binary
    case image
    case pdf

    /// Files over this size open read-only (R-ED-6).
    public static let readOnlyBytes = 8 * 1024 * 1024
    /// How much of the file the binary sniff reads.
    static let sniffBytes = 8 * 1024

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "heif", "webp", "ico", "icns",
    ]

    /// Classifies `data`, the whole file, named by `path`.
    static func classify(path: String, size: Int, head: Data) -> FileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if head.prefix(sniffBytes).contains(0) { return .binary }
        return size > readOnlyBytes ? .largeText : .text
    }
}

/// Reads and writes one file for the editor. File I/O lives in the app (ARCHITECTURE §4.4); the daemon only
/// learns paths. Saves write in place, keeping the file's inode, owner and permissions.
struct FileDocument {
    let url: URL
    private(set) var kind: FileKind = .text
    /// The bytes last read from or written to disk, to tell our own writes from external changes.
    private(set) var diskData = Data()
    private(set) var encoding: String.Encoding = .utf8

    init(path: String) {
        url = URL(filePath: path)
    }

    var path: String { url.path(percentEncoded: false) }
    var name: String { url.lastPathComponent }

    /// Reads the file and returns its text for text kinds (nil for previews and binaries).
    mutating func load() throws -> String? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        kind = FileKind.classify(path: path, size: data.count, head: data.prefix(FileKind.sniffBytes))
        diskData = data
        switch kind {
        case .image, .pdf, .binary: return nil
        case .text, .largeText:
            if let text = String(data: data, encoding: .utf8) {
                encoding = .utf8
                return text
            }
            // Not UTF-8: Latin-1 decodes any byte sequence and saves back byte for byte.
            encoding = .isoLatin1
            return String(data: data, encoding: .isoLatin1) ?? ""
        }
    }

    /// The file's bytes on disk now, or nil when it's gone or unreadable.
    func readDisk() -> Data? {
        try? Data(contentsOf: url)
    }

    /// Writes `text` in place, creating the file when it was deleted.
    mutating func save(_ text: String) throws {
        guard let data = text.data(using: encoding, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: [])
        diskData = data
    }

    /// Records bytes someone else wrote as the new baseline (after Reload, or Keep Mine).
    mutating func adopt(_ data: Data) {
        diskData = data
    }

    func decode(_ data: Data) -> String? {
        String(data: data, encoding: encoding)
    }

    var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

/// Watches one path through a `DispatchSource` vnode source (R-ED-4). An atomic save by another program
/// replaces the file, so after a delete or rename the watch re-arms on whatever is at the path now.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private let onDelete: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        self.onDelete = onDelete
        arm()
    }

    isolated deinit {
        stop()
    }

    func stop() {
        debounce?.cancel()
        source?.cancel()
        source = nil
    }

    /// Opens the path for events; false when nothing is there.
    @discardableResult
    func arm() -> Bool {
        source?.cancel()
        source = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handle() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        return true
    }

    private func handle() {
        guard let source else { return }
        let events = source.data
        if events.contains(.delete) || events.contains(.rename) {
            // The file was replaced or removed; look again once the writer is done.
            self.source?.cancel()
            self.source = nil
            schedule(after: 0.1) { [weak self] in
                guard let self else { return }
                if arm() { onChange() } else { onDelete() }
            }
            return
        }
        schedule(after: 0.05) { [weak self] in self?.onChange() }
    }

    private func schedule(after seconds: Double, _ body: @escaping @MainActor () -> Void) {
        debounce?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}

/// Recovery copies of dirty buffers (R-ED-5): `<dataDir>/recovery/<hash>.json`, holding the path, the time
/// and the text. Written every 5 s while a buffer is dirty; removed on save, reload and discard.
struct RecoveryStore {
    struct Copy: Codable {
        var path: String
        var savedAt: Date
        var text: String
    }

    let directory: URL

    func url(for path: String) -> URL {
        directory.appending(path: "\(Self.hash(path)).json", directoryHint: .notDirectory)
    }

    func write(path: String, text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = Copy(path: path, savedAt: Date(), text: text)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(copy).write(to: url(for: path), options: .atomic)
    }

    func read(path: String) -> Copy? {
        guard let data = try? Data(contentsOf: url(for: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let copy = try? decoder.decode(Copy.self, from: data), copy.path == path else { return nil }
        return copy
    }

    func remove(path: String) {
        try? FileManager.default.removeItem(at: url(for: path))
    }

    /// FNV-1a, 64 bit: a stable file name for a path.
    static func hash(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
