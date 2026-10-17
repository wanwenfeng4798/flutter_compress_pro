import AVFoundation
import Foundation

@main
enum DarwinRegression {
  static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
      throw NSError(domain: "Regression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  static func fixture(_ url: URL, rotated: Bool = false) throws {
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000],
      ])
    if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
      ])
    writer.add(input)
    try require(writer.startWriting(), "Fixture writer failed")
    writer.startSession(atSourceTime: .zero)
    var seed: UInt32 = 12345
    for frame in 0..<96 {
      let deadline = Date().addingTimeInterval(15)
      while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.002)
      }
      try require(input.isReadyForMoreMediaData, "Fixture writer stalled")
      var optional: CVPixelBuffer?
      CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, nil, &optional)
      guard let buffer = optional else { throw ConfigError.invalid }
      CVPixelBufferLockBaseAddress(buffer, [])
      guard let raw = CVPixelBufferGetBaseAddress(buffer) else { throw ConfigError.invalid }
      let bytes = raw.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      for y in 0..<360 {
        for x in 0..<640 {
          let offset = y * stride + x * 4
          seed = seed &* 1_664_525 &+ 1_013_904_223
          let noise = UInt8(truncatingIfNeeded: seed >> 16)
          var color: [UInt8] = [noise, noise, noise]
          if x < 160 && y < 90 { color = [0, 0, 255] }
          if x > 480 && y < 90 { color = [0, 255, 0] }
          if x < 160 && y > 270 { color = [255, 0, 0] }
          if x > 480 && y > 270 { color = [0, 255, 255] }
          bytes[offset] = color[0]
          bytes[offset + 1] = color[1]
          bytes[offset + 2] = color[2]
          bytes[offset + 3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      try require(
        adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)),
        "Fixture append failed")
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(seconds: 4, preferredTimescale: 1000))
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    try require(
      done.wait(timeout: .now() + 30) == .success && writer.status == .completed,
      "Fixture finalization failed")
  }

  static func corners(_ url: URL) throws -> [[Int]] {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    let image = try generator.copyCGImage(
      at: CMTime(seconds: 0.5, preferredTimescale: 1000), actualTime: nil)
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard
      let context = CGContext(
        data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ConfigError.invalid }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return [(0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)].map { x, y in
      let offset = (Int(y * Double(image.height)) * image.width + Int(x * Double(image.width))) * 4
      return pixels[offset..<(offset + 3)].map(Int.init)
    }
  }

  static func main() throws {
    let source = URL(
      fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1] : "example/assets/sample.mp4")
    try fixture(source)
    if CommandLine.arguments.contains("--fixture-only") { return }
    let engine = CompressionEngine()
    let done = DispatchSemaphore(value: 0)
    var outcome: CompressionOutcome?
    engine.compress(
      id: "regression", path: source.path,
      config: CompressionConfig(map: [
        "codec": "h264", "maxWidth": 320, "maxHeight": 320,
        "videoBitrateKbps": 300, "keepOriginalIfLarger": false,
      ])
    ) { value in
      outcome = value
      done.signal()
    }
    let deadline = Date().addingTimeInterval(60)
    while done.wait(timeout: .now()) != .success {
      try require(Date() < deadline, "Encode hung")
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard case .success(let result) = outcome, let path = result["outputPath"] as? String else {
      throw NSError(
        domain: "Regression", code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "Encode did not succeed: \(String(describing: outcome))"
        ])
    }
    let output = URL(fileURLWithPath: path)
    defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
    let info = try MediaProbe.videoInfo(path: path)
    try require(info["width"] as? Int == 320, "Wrong output width")
    try require(abs((info["durationMs"] as? Int64 ?? 0) - 4000) < 200, "Wrong output duration")
    let before = try corners(source)
    let after = try corners(output)
    for index in before.indices {
      for component in 0..<3 {
        try require(
          abs(before[index][component] - after[index][component]) < 45,
          "A corner was cropped or transformed incorrectly")
      }
    }
    let rotatedSource = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: rotatedSource) }
    try fixture(rotatedSource, rotated: true)
    let rotatedDone = DispatchSemaphore(value: 0)
    var rotatedOutcome: CompressionOutcome?
    engine.compress(id: "rotated", path: rotatedSource.path,
      config: CompressionConfig(map: ["codec": "h264", "maxWidth": 320, "maxHeight": 320,
        "keepOriginalIfLarger": false])) { rotatedOutcome = $0; rotatedDone.signal() }
    let rotatedDeadline = Date().addingTimeInterval(60)
    while rotatedDone.wait(timeout: .now()) != .success {
      try require(Date() < rotatedDeadline, "Rotated encode hung")
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard case .success(let rotatedResult) = rotatedOutcome,
      let rotatedPath = rotatedResult["outputPath"] as? String else { throw ConfigError.invalid }
    let rotatedOutput = URL(fileURLWithPath: rotatedPath)
    defer { try? FileManager.default.removeItem(at: rotatedOutput.deletingLastPathComponent()) }
    let rotatedBefore = try corners(rotatedSource), rotatedAfter = try corners(rotatedOutput)
    for index in rotatedBefore.indices {
      for component in 0..<3 {
        try require(abs(rotatedBefore[index][component] - rotatedAfter[index][component]) < 45,
          "Rotated corner was cropped")
      }
    }
    // Cancellation must resolve even if AVFoundation stops asking for samples.
    let cancelled = DispatchSemaphore(value: 0)
    var cancellation: CompressionOutcome?
    engine.compress(id: "cancel", path: source.path, config: CompressionConfig(map: [:])) { value in
      cancellation = value
      cancelled.signal()
    }
    engine.cancel(id: "cancel")
    let cancelDeadline = Date().addingTimeInterval(10)
    while cancelled.wait(timeout: .now()) != .success {
      try require(Date() < cancelDeadline, "Cancellation hung")
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard case .cancelled = cancellation else { throw ConfigError.invalid }
    print("Darwin encode, re-decode, corner scaling, metadata and cancellation: PASS")
  }
}
