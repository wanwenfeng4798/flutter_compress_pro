import AVFoundation

/// Reads source video metadata. Separated for reuse and clarity.
enum MediaProbe {
  static func videoInfo(path: String) throws -> [String: Any] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else {
      throw NSError(
        domain: "flutter_compress_pro", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No video track"])
    }
    let size = track.naturalSize.applying(track.preferredTransform)
    let seconds = CMTimeGetSeconds(asset.duration)
    guard seconds.isFinite, seconds > 0, size.width.isFinite, size.height.isFinite,
      abs(size.width) > 0, abs(size.height) > 0 else { throw ConfigError.invalid }
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    return [
      "path": path,
      "width": Int(abs(size.width)),
      "height": Int(abs(size.height)),
      "durationMs": Int64(seconds * 1000),
      "sizeBytes": fileSize,
      "bitrateKbps": Int(track.estimatedDataRate / 1000),
      "frameRate": Double(track.nominalFrameRate),
      "codec": codec(track),
      "hasAudio": !asset.tracks(withMediaType: .audio).isEmpty,
      "rotation": rotationDegrees(track.preferredTransform),
    ]
  }

  static func codec(_ track: AVAssetTrack) -> String {
    guard let desc = (track.formatDescriptions as? [CMFormatDescription])?.first else {
      return "unknown"
    }
    let kind = CMFormatDescriptionGetMediaSubType(desc)
    return kind == kCMVideoCodecType_HEVC
      ? "h265" : kind == kCMVideoCodecType_H264 ? "h264" : "unknown"
  }

  static func rotationDegrees(_ transform: CGAffineTransform) -> Int {
    let angle = atan2(transform.b, transform.a) * 180 / .pi
    return (Int(angle.rounded()) + 360) % 360
  }
}
