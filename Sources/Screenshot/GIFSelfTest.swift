import AppKit
import ImageIO

@MainActor func runGIFEncodingSelfTest() throws {
    func require(_ value: Bool, _ message: String) throws { if !value { throw CaptureError.message(message) } }
    let ctx = CGContext(data: nil, width: 1600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 400))
    let first = try GIFEncoding.frame(ctx.makeImage()!, time: 10)
    ctx.setFillColor(NSColor.blue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 400))
    let second = try GIFEncoding.frame(ctx.makeImage()!, time: 10.4)
    let data = try GIFEncoding.encode([first, second], end: 11)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CaptureError.message("GIF 无法解码") }
    try require(CGImageSourceGetCount(source) == 2, "GIF 帧数错误")
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    try require(image.width == 1280 && image.height == 320, "GIF 缩放错误")
    for (index, delay) in [0.4, 0.6].enumerated() {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)! as NSDictionary
        let gif = properties[kCGImagePropertyGIFDictionary] as! NSDictionary
        let actual = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif[kCGImagePropertyGIFDelayTime] as! Double
        try require(abs(actual - delay) < 0.02, "GIF 静态停留时序错误")
    }
    let staticData = try GIFEncoding.encode([first], end: 12)
    try require(CGImageSourceGetCount(CGImageSourceCreateWithData(staticData as CFData, nil)!) == 1, "静态录制导出失败")
    do { _ = try GIFEncoding.encode([], end: 1); throw CaptureError.message("空 GIF 应拒绝") }
    catch let error as CaptureError { if error.localizedDescription == "空 GIF 应拒绝" { throw error } }
}
