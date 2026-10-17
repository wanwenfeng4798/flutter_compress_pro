import Foundation

/// The plugin's private scratch directory for intermediate outputs/thumbnails.
enum PluginFiles {
  private static let lock = NSLock()
  private static var active = Set<String>()
  static func release(_ url: URL) {
    lock.lock()
    defer { lock.unlock() }
    active.remove(url.deletingLastPathComponent().path)
  }

  static func cacheDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flutter_compress_pro")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func clearCache() {
    let items =
      (try? FileManager.default.contentsOfDirectory(
        at: cacheDir(), includingPropertiesForKeys: nil)) ?? []
    lock.lock()
    defer { lock.unlock() }
    for item in items where !active.contains(item.path) {
      try? FileManager.default.removeItem(at: item)
    }
  }

  /// Compose the output URL. The name is `outputName` (extension stripped — the
  /// caller's contract is "base name only") or the source's base name plus a
  /// timestamp; `ext` (without dot) is always appended so it matches the bytes
  /// written. Writes into `outputDir` when it's a real writable directory,
  /// otherwise the plugin cache.
  static func resolveOutput(
    outputDir: String?, outputName: String?, sourcePath: String, ext: String
  ) throws -> URL {
    let base: String
    if let name = outputName, !name.isEmpty {
      base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
    } else {
      let srcBase = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
      base = "\(srcBase)_\(Int(Date().timeIntervalSince1970 * 1000))"
    }
    let fileName = "\(base).\(ext)"
    var target = cacheDir().appendingPathComponent(fileName)
    if let dir = outputDir, dir.hasPrefix("/") {
      let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
      try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
      if FileManager.default.isWritableFile(atPath: dir) {
        target = dirURL.appendingPathComponent(fileName)
      }
    }
    let folder = target.deletingLastPathComponent().appendingPathComponent(
      "compress-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    lock.lock()
    active.insert(folder.path)
    lock.unlock()
    return folder.appendingPathComponent(target.lastPathComponent)
  }
}
