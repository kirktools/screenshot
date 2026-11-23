import Foundation

/// 仅从 URLSession 提取数值耗时，不保留请求头、URL 或 IP。
public struct TranslationNetworkTiming: Sendable {
    public let dns: Double?
    public let tcp: Double?
    public let tls: Double?
    public let responseWait: Double?
    public let total: Double
    public let proxy: Bool
    public let reused: Bool

    init(_ transaction: URLSessionTaskTransactionMetrics, total: TimeInterval) {
        func milliseconds(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end, end >= start else { return nil }
            return end.timeIntervalSince(start) * 1000
        }
        dns = milliseconds(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        tcp = milliseconds(transaction.connectStartDate, transaction.secureConnectionStartDate ?? transaction.connectEndDate)
        tls = milliseconds(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        responseWait = milliseconds(transaction.requestEndDate, transaction.responseStartDate)
        self.total = total * 1000
        proxy = transaction.isProxyConnection
        reused = transaction.isReusedConnection
    }
}
