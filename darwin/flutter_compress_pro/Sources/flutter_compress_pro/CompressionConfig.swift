import Foundation

/// Parsed mirror of the Dart `VideoCompressConfig`.
struct CompressionConfig {
  let quality: String
  let qualityPercent: Int?
  let targetSizeMB: Int?
  let videoBitrateKbps: Int?
  let codec: String
  let maxWidth: Int?
  let maxHeight: Int?
  let frameRate: Double?
  let removeAudio: Bool
  let audioBitrateKbps: Int?
  let trimStartMs: Int64?
  let trimEndMs: Int64?
  let alignment: String
  let keepOriginalIfLarger: Bool
  let minSavingsPercent: Int
  /// "auto" (keep source container where possible) or "mp4".
  let container: String

  func validate() throws {
    let positive = [targetSizeMB, videoBitrateKbps, audioBitrateKbps, maxWidth, maxHeight]
    guard !positive.compactMap({ $0 }).contains(where: { $0 <= 0 }),
      frameRate.map({ $0.isFinite && $0 > 0 }) ?? true,
      qualityPercent.map({ (1...100).contains($0) }) ?? true,
      (0...99).contains(minSavingsPercent),
      trimStartMs.map({ start in start >= 0 && (trimEndMs.map({ $0 > start }) ?? false) }) ?? true
    else {
      throw ConfigError.invalid
    }
  }

  init(map: [String: Any]) {
    quality = map["quality"] as? String ?? "medium"
    qualityPercent = (map["qualityPercent"] as? NSNumber)?.intValue
    targetSizeMB = (map["targetSizeMB"] as? NSNumber)?.intValue
    videoBitrateKbps = (map["videoBitrateKbps"] as? NSNumber)?.intValue
    codec = map["codec"] as? String ?? "h265"
    maxWidth = (map["maxWidth"] as? NSNumber)?.intValue
    maxHeight = (map["maxHeight"] as? NSNumber)?.intValue
    frameRate = (map["frameRate"] as? NSNumber)?.doubleValue
    removeAudio = map["removeAudio"] as? Bool ?? false
    audioBitrateKbps = (map["audioBitrateKbps"] as? NSNumber)?.intValue
    let trim = map["trim"] as? [String: Any]
    trimStartMs = (trim?["startMs"] as? NSNumber)?.int64Value
    trimEndMs = (trim?["endMs"] as? NSNumber)?.int64Value
    alignment = map["alignment"] as? String ?? "auto16"
    keepOriginalIfLarger = map["keepOriginalIfLarger"] as? Bool ?? true
    minSavingsPercent = (map["minSavingsPercent"] as? NSNumber)?.intValue ?? 0
    container = map["container"] as? String ?? "auto"
  }
}

/// The three ways a `compress` call can end.
enum CompressionOutcome {
  case success([String: Any])
  case cancelled
  case failure(String)
}

enum ConfigError: LocalizedError {
  case invalid
  var errorDescription: String? { "Invalid compression configuration" }
}
