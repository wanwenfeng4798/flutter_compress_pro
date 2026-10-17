import Foundation

extension CompressionEngine {
  func estimate(path: String, config: CompressionConfig) throws -> [String: Any] {
    try config.validate()
    let info = try MediaProbe.videoInfo(path: path)
    // Read defensively rather than force-casting: the probe's value types are an
    // implicit cross-file contract, and a force cast would crash the host app
    // instead of surfacing as an `estimate_failed` error.
    guard let srcW = info["width"] as? Int,
      let srcH = info["height"] as? Int,
      let fullDuration = info["durationMs"] as? Int64,
      let srcKbps = info["bitrateKbps"] as? Int
    else { throw ConfigError.invalid }
    if let start = config.trimStartMs, start >= fullDuration { throw ConfigError.invalid }
    let durationMs = clampDuration(fullDuration, config)
    let (tw, th) = SizeMath.targetDimensions(srcW: srcW, srcH: srcH, config: config)
    let videoBps = SizeMath.videoBitrateBps(
      config: config, durationMs: durationMs,
      sourceBitrateKbps: srcKbps, targetHeight: th)
    let audioBps = config.removeAudio ? 0 : (config.audioBitrateKbps ?? 128) * 1000
    let totalBits = Int64(videoBps + audioBps) * durationMs / 1000
    return [
      "estimatedSizeBytes": totalBits / 8,
      "estimatedBitrateKbps": (videoBps + audioBps) / 1000,
      "targetWidth": tw,
      "targetHeight": th,
    ]
  }

}
