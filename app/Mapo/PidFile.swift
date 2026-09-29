import Foundation

/// `<runtime>/<instance>.app.pid`: line 1 the pid, line 2 the executable (ENGINEERING §2.2). Written at
/// launch with mode 0600 and removed at exit, if it is still ours.
struct PidFile {
    let path: String
    private let contents: String

    init(path: String) {
        self.path = path
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        contents = "\(ProcessInfo.processInfo.processIdentifier)\n\(executable)\n"
    }

    func write() throws {
        let url = URL(filePath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appending(component: ".\(url.lastPathComponent).tmp")
        FileManager.default.createFile(
            atPath: temporary.path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o600])
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func remove() {
        guard let current = try? String(contentsOfFile: path, encoding: .utf8), current == contents else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
