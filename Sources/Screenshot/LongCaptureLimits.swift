import Foundation

/// 捕获和导出共用资源预算，不按固定高度提前截断。
/// 为条带、输出位图、PNG 编码及剪贴板副本预留空间；不自动缩小图片。
struct LongCaptureLimits {
    let retainedBytes: Int
    let pixels: Int
    init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        let working = Int(min(1_500_000_000, max(256_000_000, physicalMemory / 6)))
        retainedBytes = working / 3
        pixels = working / 16
    }
    func accepts(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let product = width.multipliedReportingOverflow(by: height)
        return !product.overflow && product.partialValue <= pixels
    }
}
