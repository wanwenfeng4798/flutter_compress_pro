import AVFoundation
import Foundation

/// Construction details shared by both codec attempts.
enum VideoPipeline {
  static func composition(asset: AVAsset, track: AVAssetTrack, width: Int, height: Int, fps: Double)
    -> AVMutableVideoComposition {
    let composition = AVMutableVideoComposition()
    composition.renderSize = CGSize(width: width, height: height)
    composition.frameDuration = CMTime(seconds: 1 / max(fps, 1), preferredTimescale: 60000)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    let bounds = CGRect(origin: .zero, size: track.naturalSize).applying(
      track.preferredTransform)
    let upright = track.preferredTransform.concatenating(
      CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    let scale = CGAffineTransform(
      scaleX: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
    layer.setTransform(upright.concatenating(scale), at: .zero)
    instruction.layerInstructions = [layer]
    composition.instructions = [instruction]

    return composition
  }
  static func settings(codec: AVVideoCodecType, bitrate: Int, width: Int, height: Int, fps: Double)
    -> [String: Any] {
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: bitrate,
      AVVideoMaxKeyFrameIntervalKey: Int(max(fps, 1) * 2),
      // Apple recommends declaring the source frame rate: without it the rate
      // controller has to guess the frame cadence, which makes the average
      // bitrate — and therefore a requested target size — less accurate.
      AVVideoExpectedSourceFrameRateKey: Int(max(fps, 1)),
    ]
    if codec == .h264 {
      compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    }
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
    ]
    return videoSettings
  }
  static func supportsHEVCEncoding() -> Bool {
    if #available(iOS 11.0, *) {
      return AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
    }
    return false
  }

}

/// Balances a pump's group entry across callbacks, cancellation and failure.
final class PumpCompletion {
  private let lock = NSLock()
  private let group: DispatchGroup
  private var finished = false
  init(_ group: DispatchGroup) {
    self.group = group
    group.enter()
  }
  func finish() {
    lock.lock()
    defer { lock.unlock() }
    if !finished {
      finished = true
      group.leave()
    }
  }
}
