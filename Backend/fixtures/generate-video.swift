// Synthetic four-second H.264 test clip. No remote media or copyrighted footage.
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

func generate() throws {
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "sample.mp4")
let temporary = output.appendingPathExtension("partial.mp4")
try? FileManager.default.removeItem(at: temporary)
let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
let width = 320
let height = 568
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 150_000]
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
])
writer.add(input)
guard writer.startWriting() else { throw writer.error! }
writer.startSession(atSourceTime: .zero)
for frame in 0..<48 {
    while !input.isReadyForMoreMediaData {
        guard writer.status == .writing else { throw writer.error ?? NSError(domain: "FixtureEncoder", code: 1) }
        usleep(1_000)
    }
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { fatalError("Pixel buffer allocation failed") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    context.setFillColor(CGColor(red: 0.055, green: 0.065, blue: 0.10, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.95, green: 0.20, blue: 0.31, alpha: 1))
    context.fillEllipse(in: CGRect(x: 100, y: 224, width: 120, height: 120))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.beginPath()
    context.move(to: CGPoint(x: 146, y: 252))
    context.addLine(to: CGPoint(x: 146, y: 316))
    context.addLine(to: CGPoint(x: 190, y: 284))
    context.closePath()
    context.fillPath()
    context.setFillColor(CGColor(red: 0.95, green: 0.20, blue: 0.31, alpha: 1))
    context.fill(CGRect(x: 24, y: 60, width: 272 * Double(frame + 1) / 48, height: 8))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)) else { throw writer.error! }
}
input.markAsFinished()
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
finished.wait()
guard writer.status == .completed else { throw writer.error! }
try? FileManager.default.removeItem(at: output)
try FileManager.default.moveItem(at: temporary, to: output)
print("Generated synthetic H.264 MP4: \(output.lastPathComponent)")
}
do { try generate() }
catch {
    FileHandle.standardError.write(Data("Fixture encoding failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
