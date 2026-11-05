import Foundation

/// 仅记录阶段与耗时，不读取或持久化像素、窗口标题、应用列表或按键内容。
final class CaptureTiming: @unchecked Sendable {
    @TaskLocal static var current: CaptureTiming?
    private static let runID = UUID().uuidString
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: "diagnostics.captureTiming") as? Bool) ?? (ApplicationFlavor.isDevelopment || ProcessInfo.processInfo.environment["SCREENSHOT_CAPTURE_TIMING"] == "1")
    }
    static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs").appendingPathComponent(ApplicationFlavor.name)
    }
    static func clear(completion: @escaping @Sendable (Bool) -> Void) {
        writer.async {
            do {
                for name in ["capture-timing.jsonl", "capture-timing.previous.jsonl"] {
                    let url = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                }
                completion(true)
            } catch { completion(false) }
        }
    }
    private static let writer = DispatchQueue(label: "screenshot.capture-timing", qos: .utility)
    private let lock = NSLock()
    private let start = ProcessInfo.processInfo.systemUptime
    private let date = Date()
    private let source: String
    private let active: Bool
    private var events: [[String: Any]] = []
    private var ended = false
    init(source: String) {
        let testing = CommandLine.arguments.contains { $0.contains("self-test") || $0.contains("smoke-test") }
        self.source = testing ? "test." + source : source
        active = Self.enabled
    }
    func mark(_ stage: String, value: Double? = nil) {
        guard active else { return }
        lock.lock(); defer { lock.unlock() }
        guard !ended, events.count < 64 else { return }
        var event: [String: Any] = ["stage": stage, "elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000]
        if let value { event["value"] = value }
        events.append(event)
    }
    func finish(_ outcome: String) {
        guard active else { return }
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        let record: [String: Any] = ["schema": 1, "run_id": Self.runID, "timestamp": date.timeIntervalSince1970,
            "source": source, "outcome": outcome, "total_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
            "events": events]
        lock.unlock()
        // 写盘排在截图关键路径之后；单文件约 1 MB，最多保留一份轮转备份。
        Self.writer.async {
            do {
                let directory = Self.directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("capture-timing.jsonl")
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 1_048_576 {
                    let backup = directory.appendingPathComponent("capture-timing.previous.jsonl")
                    if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
                    try FileManager.default.moveItem(at: url, to: backup)
                }
                var serialized = record
                if let timestamp = record["timestamp"] as? Double {
                    serialized["timestamp"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timestamp))
                }
                var data = try JSONSerialization.data(withJSONObject: serialized, options: [.sortedKeys]); data.append(10)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            } catch { /* 诊断写入失败不能影响截图。 */ }
        }
    }
}
