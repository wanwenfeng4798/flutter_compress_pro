import Foundation

/// Persist a finished file where the user can find it.
///
/// - iOS: app Documents (Files app with UIFileSharingEnabled).
/// - macOS: user Downloads folder.
enum DownloadSaver {
  static func save(path: String, fileName: String?) throws -> String {
    #if os(iOS)
      let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    #else
      let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    #endif
    let source = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    let name = ((fileName ?? source.lastPathComponent) as NSString).lastPathComponent
    let wanted = folder.appendingPathComponent(name)
    if wanted.resolvingSymlinksInPath().standardizedFileURL == source { return source.path }
    let fm = FileManager.default
    let staging = folder.appendingPathComponent(".compress-save-" + UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    let copy = staging.appendingPathComponent("copy")
    try fm.copyItem(at: source, to: copy)
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    for index in 0..<10000 {
      let suffix = index == 0 ? "" : "-\(index)"
      let leaf = base + suffix + (ext.isEmpty ? "" : "." + ext)
      let dest = folder.appendingPathComponent(leaf)
      do {
        try fm.moveItem(at: copy, to: dest)
        return dest.path
      } catch let error as NSError where error.code == NSFileWriteFileExistsError { continue }
    }
    throw CocoaError(.fileWriteFileExists)
  }
}
