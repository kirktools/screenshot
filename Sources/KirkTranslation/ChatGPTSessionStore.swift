import Darwin
import Foundation

/// OpenAI 的原生客户端使用仅当前用户可访问的本地授权记录。
struct ChatGPTSessionStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("session.json") }

    func read() throws -> Data? {
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) != 0 {
            if errno == ENOENT { return nil }
            throw ChatGPTPlan.Failure.sessionStorageUnavailable
        }
        try checkDirectory(directoryInfo)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw ChatGPTPlan.Failure.sessionStorageUnavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 128 * 1024
        else { throw ChatGPTPlan.Failure.sessionStorageUnavailable }
        guard let bytes = try handle.read(upToCount: 128 * 1024 + 1), bytes.count <= 128 * 1024 else {
            throw ChatGPTPlan.Failure.sessionStorageUnavailable
        }
        return bytes
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw ChatGPTPlan.Failure.sessionStorageUnavailable
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw ChatGPTPlan.Failure.sessionStorageUnavailable }
        try checkDirectory(info)

        let tmp = directory.appendingPathComponent(UUID().uuidString)
        let descriptor = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ChatGPTPlan.Failure.sessionStorageUnavailable }
        defer { _ = unlink(tmp.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(tmp.path, file.path) == 0 else { throw ChatGPTPlan.Failure.sessionStorageUnavailable }
    }

    private func checkDirectory(_ info: stat) throws {
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700
        else { throw ChatGPTPlan.Failure.sessionStorageUnavailable }
    }
}
