import CoreImage
import CoreVideo
import UIKit

/// One transient decoded preview image. Never persisted or used as a playback source.
@MainActor
struct PlaybackTransitionFrame: Identifiable {
    static let maximumPixelLength = 960
    static let maximumPositionDifference: Double = 2
    let id: UUID
    let seriesID: String
    let episodeID: String
    let seconds: Double
    let image: UIImage

    init?(id: UUID = UUID(), seriesID: String, episodeID: String, seconds: Double, image: UIImage) {
        guard !seriesID.isEmpty, !episodeID.isEmpty, seconds.isFinite, seconds >= 0,
              let bitmap = image.cgImage, bitmap.width > 0, bitmap.height > 0,
              max(bitmap.width, bitmap.height) <= Self.maximumPixelLength else { return nil }
        self.id = id; self.seriesID = seriesID; self.episodeID = episodeID
        self.seconds = seconds; self.image = image
    }

    func matches(seriesID: String, episodeID: String, seconds: Double) -> Bool {
        self.seriesID == seriesID && self.episodeID == episodeID && seconds.isFinite && seconds >= 0
            && abs(self.seconds - seconds) <= Self.maximumPositionDifference
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func make(pixelBuffer: CVPixelBuffer, seriesID: String, episodeID: String,
                     seconds: Double, presentationSize: CGSize) -> PlaybackTransitionFrame? {
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = input.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0,
              presentationSize.width.isFinite, presentationSize.height.isFinite,
              presentationSize.width > 0, presentationSize.height > 0 else { return nil }
        // Do not guess a track's rotation or anamorphic transform. A buffer whose
        // shape differs from the presented picture simply uses the normal fallback.
        let bufferAspect = extent.width / extent.height
        let displayAspect = presentationSize.width / presentationSize.height
        guard abs(bufferAspect - displayAspect) <= max(displayAspect * 0.02, 0.01) else { return nil }
        let scale = min(1, CGFloat(maximumPixelLength) / max(extent.width, extent.height))
        let width = max(1, Int(floor(extent.width * scale)))
        let height = max(1, Int(floor(extent.height * scale)))
        let normalized = input.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let thumbnail = normalized.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                                                    y: CGFloat(height) / extent.height))
        guard let bitmap = context.createCGImage(thumbnail, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
        return .init(seriesID: seriesID, episodeID: episodeID, seconds: seconds,
                     image: UIImage(cgImage: bitmap, scale: 1, orientation: .up))
    }
}
