/// 将已生成的 6 fps 合成分镜编码为 24 秒 H.264，不读取桌面。
import Foundation
import AVFoundation
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = root.appendingPathComponent("features-demo.mp4")
if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1800000]])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720])
writer.add(input)
guard writer.startWriting() else { fatalError("编码启动失败：\(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)
let frameCount = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("frames").path).filter { $0.hasSuffix(".png") }.count
guard frameCount == 144 else { fatalError("需要 144 帧（24 秒 / 6 fps）的演示素材") }
for i in 0..<frameCount {
    let url = root.appendingPathComponent(String(format: "frames/%04d.png", i))
    let image = NSImage(contentsOf: url)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let b = buffer!
    CVPixelBufferLockBaseAddress(b, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(b), width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1280, height: 720))
    CVPixelBufferUnlockBaseAddress(b, [])
    for repeatIndex in 0..<5 {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        guard adaptor.append(b, withPresentationTime: CMTime(value: Int64(i * 5 + repeatIndex), timescale: 30)) else { fatalError("写入失败：\(String(describing: writer.error))") }
    }
}
input.markAsFinished()
let semaphore = DispatchSemaphore(value: 0)
writer.finishWriting { semaphore.signal() }
semaphore.wait()
guard writer.status == .completed else { fatalError("编码失败：\(String(describing: writer.error))") }
print("已生成 MP4：\(output.lastPathComponent)")
