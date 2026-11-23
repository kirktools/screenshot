import Foundation
import KirkLogging

/// 将截图操作的阶段、耗时和关联编号交给共享日志包。
final class CaptureTiming: @unchecked Sendable {
    @TaskLocal static var current: CaptureTiming?
    enum Level: String, CaseIterable {
        case off, error, warning, info, debug

        var title: String {
            switch self {
            case .off: return "关闭"
            case .error: return "仅错误"
            case .warning: return "警告及错误"
            case .info: return "操作与结果"
            case .debug: return "详细阶段"
            }
        }

        func includes(_ entry: DiagnosticLevel) -> Bool {
            switch self {
            case .off: return false
            case .error: return entry == .error
            case .warning: return entry == .warning || entry == .error
            case .info: return entry != .debug
            case .debug: return true
            }
        }

        static func resolve(saved: String?, legacyEnabled: Bool?, isDevelopment: Bool) -> Self {
            if let saved, let level = Self(rawValue: saved) { return level }
            if let legacyEnabled { return legacyEnabled ? .debug : .off }
            return isDevelopment ? .debug : .warning
        }
    }

    private static let preference = "diagnostics.level"
    static var level: Level {
        let defaults = UserDefaults.standard
        return Level.resolve(saved: defaults.string(forKey: preference),
                             legacyEnabled: defaults.object(forKey: "diagnostics.captureTiming") as? Bool,
                             isDevelopment: ApplicationFlavor.isDevelopment)
    }

    private static let writer = Result {
        let bundle = Bundle.main
        return try DiagnosticLog(configuration: .init(
            app: "Screenshot", channel: ApplicationFlavor.isDevelopment ? .dev : .release, role: "host",
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            archivedFiles: 1
        ), enabled: true)
    }

    static func log() throws -> DiagnosticLog { try writer.get() }

    static func setLevel(_ level: Level) {
        UserDefaults.standard.set(level.rawValue, forKey: preference)
    }

    static func recordOutcome(_ outcome: StaticString, source: StaticString, operationID: UUID, error: StaticString? = nil) {
        let severity: DiagnosticLevel = error == nil ? .info : .error
        guard level.includes(severity) else { return }
        (try? log())?.record(severity, module: source, event: outcome, operationID: operationID, errorCode: error)
    }

    private let start = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private let source: StaticString
    private let log: DiagnosticLog?
    private let minimumLevel: @Sendable () -> Level
    let operationID: UUID
    private var ended = false

    convenience init(source: StaticString, operationID: UUID = UUID()) {
        let testing = CommandLine.arguments.contains { $0.hasSuffix("-test") }
        self.init(source: source, operationID: operationID, log: testing || Self.level == .off ? nil : try? Self.log(),
                  minimumLevel: { Self.level })
    }

    init(source: StaticString, operationID: UUID = UUID(), log: DiagnosticLog?,
         minimumLevel: @escaping @Sendable () -> Level = { .debug }) {
        self.source = source
        self.operationID = operationID
        self.log = log
        self.minimumLevel = minimumLevel
        if minimumLevel().includes(.info) {
            log?.record(.info, module: source, event: "started", operationID: operationID)
        }
    }

    private var elapsed: Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }

    func mark(_ stage: StaticString, elapsedMS: Double? = nil, error: StaticString? = nil) {
        let severity: DiagnosticLevel = error == nil ? .debug : .error
        guard let log, minimumLevel().includes(severity) else { return }
        lock.withLock {
            guard !ended else { return }
            log.record(severity, module: source, event: stage, operationID: operationID,
                       errorCode: error, elapsedMS: elapsedMS ?? elapsed)
        }
    }

    func httpStatus(_ status: Int) {
        switch status {
        case 200...299: mark("http.2xx")
        case 401: mark("http.401")
        case 403: mark("http.403")
        case 429: mark("http.429")
        case 400...499: mark("http.4xx")
        case 500...599: mark("http.5xx")
        default: mark("http.other")
        }
    }

    func finish(_ outcome: StaticString, error: StaticString? = nil, level: DiagnosticLevel? = nil) {
        guard let log else { return }
        lock.withLock {
            guard !ended else { return }
            ended = true
            let severity = level ?? (error != nil ? .error : .info)
            guard minimumLevel().includes(severity) else { return }
            log.record(severity, module: source, event: outcome, operationID: operationID, errorCode: error, elapsedMS: elapsed)
        }
    }
}
