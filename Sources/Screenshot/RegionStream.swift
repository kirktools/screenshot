import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

struct CapturedFrame: @unchecked Sendable {
    let image: CGImage
    let time: Double
}

@MainActor protocol RegionFrameStream: AnyObject {
    var frames: AsyncThrowingStream<CapturedFrame, Error> { get }
    func start() async throws
    func setPaused(_ paused: Bool)
    func stop() async
}

private final class StreamGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    func set(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
    var active: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
}

/// 回调只复制像素并投递到有界队列，不等待识别，也不把 IOSurface 留给慢消费者。
@MainActor final class MacRegionStream: NSObject, RegionFrameStream, SCStreamOutput, SCStreamDelegate {
    let frames: AsyncThrowingStream<CapturedFrame, Error>
    private let continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    private let queue = DispatchQueue(label: "com.kirktools.screenshot.capture", qos: .userInitiated)
    private let gate = StreamGate()
    private var stopTask: Task<Void, Never>?
    private var stream: SCStream?
    init(filter: SCContentFilter, configuration: SCStreamConfiguration) throws {
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(2))
        frames = pair.stream; continuation = pair.continuation
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }
    func start() async throws { try await stream?.startCapture() }
    func setPaused(_ paused: Bool) { gate.set(!paused) }
    func stop() async {
        if let stopTask { await stopTask.value; return }
        setPaused(true)
        let retained = stream
        let output = self
        let cleanup = Task {
            if let retained { try? await retained.stopCapture(); try? retained.removeStreamOutput(output, type: .screen) }
            // 已获准的最后一帧可能仍在回调队列中复制；先排空，再关闭消费者队列。
            await withCheckedContinuation { continuation in
                self.queue.async { continuation.resume() }
            }
            self.stream = nil; self.continuation.finish()
        }
        stopTask = cleanup
        await cleanup.value
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) { continuation.finish(throwing: error) }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard gate.active, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        autoreleasepool {
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            // Data(bytes:) 深拷贝；消费和取消过程均不持有系统帧的 IOSurface。
            let bytes = Data(bytes: base, count: row * height) as CFData
            guard let provider = CGDataProvider(data: bytes),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: row, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
            continuation.yield(CapturedFrame(image: image, time: ProcessInfo.processInfo.systemUptime))
        }
    }
}
