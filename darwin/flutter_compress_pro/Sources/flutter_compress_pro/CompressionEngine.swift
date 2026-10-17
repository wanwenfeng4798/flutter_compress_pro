import AVFoundation
import Foundation

/// AVAssetReader/Writer transcoding pipeline (iOS + macOS).
///
/// Unlike an `AVAssetExportSession` preset, this lets us set an *explicit*
/// average bitrate (`AVVideoAverageBitRateKey`), which is what makes precise
/// target-size compression possible. No FFmpeg.
final class CompressionEngine {

  /// Minimum gap between progress events, matching Android's 250ms polling.
  fileprivate static let progressIntervalSec: TimeInterval = 0.25

  var onProgress: (([String: Any]) -> Void)?

  private let lock = NSLock()
  private var reader: AVAssetReader?
  private var writer: AVAssetWriter?
  private var activeId: String?
  private var cancelled = false
  private var busy = false
  /// Set when a cancel arrives for a job that hasn't registered itself yet.
  private var preCancelledId: String?
  private let backgroundTask = BackgroundTask()

  private let videoQueue = DispatchQueue(label: "flutter_compress_pro.video")
  private let audioQueue = DispatchQueue(label: "flutter_compress_pro.audio")

  func isCompressing() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return busy
  }

  // MARK: - Estimate

  // MARK: - Compress

  func compress(
    id: String, path: String, config: CompressionConfig,
    outputDir: String? = nil, outputName: String? = nil,
    completion: @escaping (CompressionOutcome) -> Void
  ) {
    do { try config.validate() } catch {
      completion(.failure(error.localizedDescription))
      return
    }
    lock.lock()
    guard !busy else {
      lock.unlock()
      completion(.failure("Video engine is busy"))
      return
    }
    busy = true
    activeId = id
    cancelled = preCancelledId == id
    preCancelledId = nil
    lock.unlock()
    let complete: (CompressionOutcome) -> Void = { outcome in
      self.lock.lock()
      self.busy = false
      self.activeId = nil
      self.lock.unlock()
      completion(outcome)
    }
    encode(
      id: id, path: path, config: config, outputDir: outputDir, outputName: outputName,
      forceH264: false
    ) { outcome in
      if case .failure = outcome, config.codec == "h265", !self.isCancelled() {
        self.encode(
          id: id, path: path, config: config, outputDir: outputDir,
          outputName: outputName, forceH264: true, completion: complete)
      } else {
        complete(outcome)
      }
    }
  }

  // One linear AVFoundation pipeline: probe, build the reader, build the writer,
  // pump both tracks, finalise. Splitting it would mean threading ~15 derived
  // values (dimensions, bitrate, codec, fps, trim range, the `finish` closure)
  // through helper signatures, which hides the sequence rather than clarifying
  // it. Exempted here specifically so the limits keep applying everywhere else.
  // swiftlint:disable:next function_body_length cyclomatic_complexity
  private func encode(
    id: String, path: String, config: CompressionConfig,
    outputDir: String? = nil, outputName: String? = nil,
    forceH264: Bool,
    completion: @escaping (CompressionOutcome) -> Void
  ) {
    if isCancelled() {
      completion(.cancelled)
      return
    }
    var outputURL: URL?
    var localReader: AVAssetReader?
    var localWriter: AVAssetWriter?
    var videoCompletion: PumpCompletion?
    var audioCompletion: PumpCompletion?
    var watchdog: DispatchSourceTimer?
    backgroundTask.begin()
    // The de-dup state lives outside `self` on purpose: if the engine is torn
    // down mid-export, `finish` must still deliver `completion`, or the caller's
    // future never resolves.
    let finishLock = NSLock()
    var didFinish = false
    let finish: (CompressionOutcome) -> Void = { [weak self] outcome in
      finishLock.lock()
      if didFinish {
        finishLock.unlock()
        return
      }
      didFinish = true
      finishLock.unlock()
      watchdog?.cancel()
      if case .success = outcome {
      } else {
        videoCompletion?.finish()
        audioCompletion?.finish()
        localReader?.cancelReading()
        if localWriter?.status == .writing { localWriter?.cancelWriting() }
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
      }
      if let url = outputURL { PluginFiles.release(url) }
      self?.clearActiveJob()
      self?.backgroundTask.end()
      completion(outcome)
    }

    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      finish(.failure("No video track"))
      return
    }
    let originalSize =
      (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0

    let srcSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
    let seconds = CMTimeGetSeconds(asset.duration)
    guard seconds.isFinite, seconds > 0, srcSize.width.isFinite, srcSize.height.isFinite,
      abs(srcSize.width) > 0, abs(srcSize.height) > 0 else {
      finish(.failure("Invalid video metadata")); return
    }
    let srcW = Int(abs(srcSize.width))
    let srcH = Int(abs(srcSize.height))
    let fullDurationMs = Int64(seconds * 1000)
    if let start = config.trimStartMs, start >= fullDurationMs {
      finish(.failure("Trim starts beyond media duration"))
      return
    }
    let durationMs = clampDuration(fullDurationMs, config)
    let (tw, th) = SizeMath.targetDimensions(srcW: srcW, srcH: srcH, config: config)
    let videoBps = SizeMath.videoBitrateBps(
      config: config, durationMs: durationMs,
      sourceBitrateKbps: Int(videoTrack.estimatedDataRate / 1000), targetHeight: th)

    // Output codec + fallback.
    let wantHEVC = !forceH264 && config.codec == "h265" && VideoPipeline.supportsHEVCEncoding()
    let codecType: AVVideoCodecType = wantHEVC ? .hevc : .h264
    let usedCodec = wantHEVC ? "h265" : "h264"

    let fps = min(
      Double(videoTrack.nominalFrameRate == 0 ? 30 : videoTrack.nominalFrameRate),
      config.frameRate ?? 1_000_000)

    // Trim range.
    let startTime = CMTime(value: config.trimStartMs ?? 0, timescale: 1000)
    let dur = CMTime(value: durationMs, timescale: 1000)
    let timeRange = CMTimeRange(start: startTime, duration: dur)

    // Reader with a video composition — this bakes in rotation and scales to
    // the target render size in one pass.
    let composition = VideoPipeline.composition(
      asset: asset, track: videoTrack, width: tw, height: th, fps: fps)

    guard let reader = try? AVAssetReader(asset: asset) else {
      finish(.failure("Could not create reader"))
      return
    }
    localReader = reader
    reader.timeRange = timeRange

    let videoReaderOutput = AVAssetReaderVideoCompositionOutput(
      videoTracks: asset.tracks(withMediaType: .video),
      videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String:
          Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
      ])
    videoReaderOutput.videoComposition = composition
    guard reader.canAdd(videoReaderOutput) else {
      finish(.failure("Cannot add video output"))
      return
    }
    reader.add(videoReaderOutput)

    // Writer. Container: `auto` keeps a `.mov` source as `.mov` (AVFoundation
    // supports it), everything else → `.mp4`. `mp4` always forces `.mp4`.
    let srcExt = (path as NSString).pathExtension.lowercased()
    let keepMov = config.container == "auto" && srcExt == "mov"
    let fileType: AVFileType = keepMov ? .mov : .mp4
    let ext = keepMov ? "mov" : "mp4"
    let outURL: URL
    do {
      outURL = try PluginFiles.resolveOutput(
        outputDir: outputDir, outputName: outputName, sourcePath: path, ext: ext)
    } catch {
      finish(.failure(error.localizedDescription))
      return
    }
    outputURL = outURL
    guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: fileType) else {
      finish(.failure("Could not create writer"))
      return
    }

    localWriter = writer
    let videoSettings = VideoPipeline.settings(
      codec: codecType, bitrate: videoBps, width: tw, height: th, fps: fps)
    let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoWriterInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoWriterInput) else {
      finish(.failure("Cannot add video input"))
      return
    }
    writer.add(videoWriterInput)

    // Audio (optional).
    var audioReaderOutput: AVAssetReaderTrackOutput?
    var audioWriterInput: AVAssetWriterInput?
    if !config.removeAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
      let aOut = AVAssetReaderTrackOutput(
        track: audioTrack,
        outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
      if reader.canAdd(aOut) {
        reader.add(aOut)
        audioReaderOutput = aOut
      }
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 2,
        AVSampleRateKey: 44100,
        AVEncoderBitRateKey: (config.audioBitrateKbps ?? 128) * 1000,
      ]
      let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      aIn.expectsMediaDataInRealTime = false
      if writer.canAdd(aIn) {
        writer.add(aIn)
        audioWriterInput = aIn
      }
    }

    self.lock.lock()
    self.reader = reader
    self.writer = writer
    self.lock.unlock()

    guard reader.startReading() else {
      finish(.failure("Reader failed to start: \(reader.error?.localizedDescription ?? "")"))
      return
    }
    guard writer.startWriting() else {
      finish(.failure("Writer failed to start: \(writer.error?.localizedDescription ?? "")"))
      return
    }
    writer.startSession(atSourceTime: startTime)

    let group = DispatchGroup()
    let durationSec = max(CMTimeGetSeconds(dur), 0.001)
    let startSec = CMTimeGetSeconds(startTime)

    // Video pump. Progress is throttled: emitting per frame would mean a file
    // stat + a main-thread hop + a platform-channel message ~1800 times for a
    // 60s/30fps clip, starving the UI. (Android polls every 250ms.)
    var lastEmit = Date.distantPast
    let videoDone = PumpCompletion(group)
    videoCompletion = videoDone
    // `[weak self]` is load-bearing, not hygiene: the writer is a stored
    // property, the writer owns this input, and the input owns this block —
    // capturing `self` strongly closes the ring and pins the engine (plus its
    // encode session) for as long as the input keeps the block. Every exit
    // path must still `markAsFinished()` + `leave()`, or `group.notify` never
    // fires and the caller's future hangs.
    videoWriterInput.requestMediaDataWhenReady(
      on: videoQueue
    ) { [weak self, weak videoWriterInput, weak writer] in
      guard let self = self, let videoWriterInput = videoWriterInput, let writer = writer else {
        videoDone.finish()
        return
      }
      autoreleasepool {
        while videoWriterInput.isReadyForMoreMediaData {
          if self.isCancelled() {
            videoWriterInput.markAsFinished()
            videoDone.finish()
            return
          }
          guard let sample = videoReaderOutput.copyNextSampleBuffer() else {
            videoWriterInput.markAsFinished()
            videoDone.finish()
            return
          }
          let now = Date()
          if now.timeIntervalSince(lastEmit) >= Self.progressIntervalSec {
            lastEmit = now
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let progress = min(max((pts - startSec) / durationSec, 0), 1)
            let outBytes =
              (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int64)
              ?? 0
            self.onProgress?([
              "id": id,
              "progress": progress,
              "estimatedRemainingMs": NSNull(),
              "currentOutputBytes": outBytes,
            ])
          }
          guard videoWriterInput.append(sample) else {
            videoWriterInput.markAsFinished()
            videoDone.finish()
            finish(.failure(writer.error?.localizedDescription ?? "Video append failed"))
            return
          }
        }
      }
    }

    // Audio pump.
    if let aIn = audioWriterInput, let aOut = audioReaderOutput {
      let audioDone = PumpCompletion(group)
      audioCompletion = audioDone
      aIn.requestMediaDataWhenReady(on: audioQueue) { [weak self, weak aIn, weak writer] in
        guard let self = self, let aIn = aIn, let writer = writer else {
          audioDone.finish()
          return
        }
        while aIn.isReadyForMoreMediaData {
          if self.isCancelled() {
            aIn.markAsFinished()
            audioDone.finish()
            return
          }
          if let sample = aOut.copyNextSampleBuffer() {
            guard aIn.append(sample) else {
              aIn.markAsFinished()
              audioDone.finish()
              finish(.failure(writer.error?.localizedDescription ?? "Audio append failed"))
              return
            }
          } else {
            aIn.markAsFinished()
            audioDone.finish()
            return
          }
        }
      }
    }

    let timer = DispatchSource.makeTimerSource(queue: self.videoQueue)
    watchdog = timer
    timer.schedule(deadline: .now(), repeating: .milliseconds(250))
    timer.setEventHandler { [weak self] in
      guard let self = self, !self.isCancelled() else {
        finish(.cancelled)
        return
      }
      if writer.status == .failed || reader.status == .failed {
        finish(
          .failure(
            writer.error?.localizedDescription ?? reader.error?.localizedDescription
              ?? "Encoding failed"))
      }
    }
    timer.resume()

    group.notify(queue: self.videoQueue) { [weak self] in
      finishLock.lock()
      let alreadyFinished = didFinish
      finishLock.unlock()
      if alreadyFinished { return }
      // A vanished engine is treated as a cancel: there is nobody left to hand
      // the output to, so tear the writer down instead of finalising a file no
      // one will read.
      guard let self = self, !self.isCancelled() else {
        reader.cancelReading()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outURL)
        finish(.cancelled)
        return
      }
      if reader.status == .failed {
        // Abandoning a writing AVAssetWriter leaks its encode session and
        // leaves a half-written file in the cache.
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outURL)
        finish(.failure(reader.error?.localizedDescription ?? "Reader failed"))
        return
      }
      writer.finishWriting {
        if writer.status == .completed {
          let compressedSize =
            (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int64) ?? 0
          if SizeMath.keepsOriginal(
            compressedBytes: compressedSize, originalBytes: originalSize,
            keepOriginalIfLarger: config.keepOriginalIfLarger,
            minSavingsPercent: config.minSavingsPercent) {
            try? FileManager.default.removeItem(at: outURL)
            finish(
              .success([
                "id": id, "outputPath": path,
                "originalSizeBytes": originalSize, "compressedSizeBytes": originalSize,
                "width": srcW, "height": srcH, "durationMs": fullDurationMs,
                "codec": MediaProbe.codec(videoTrack), "skipped": true,
                "frameRate": Double(videoTrack.nominalFrameRate),
                "hasAudio": !asset.tracks(withMediaType: .audio).isEmpty,
              ]))
          } else {
            // Measure the file we wrote rather than echoing the source: a short
            // output is the signature of a truncated encode.
            let written = AVURLAsset(url: outURL)
            let outDurationMs = Int64(CMTimeGetSeconds(written.duration) * 1000)
            let hasAudio = !written.tracks(withMediaType: .audio).isEmpty
            finish(
              .success([
                "id": id, "outputPath": outURL.path,
                "originalSizeBytes": originalSize, "compressedSizeBytes": compressedSize,
                "width": tw, "height": th,
                "durationMs": outDurationMs > 0 ? outDurationMs : durationMs,
                "frameRate": fps, "hasAudio": hasAudio,
                "codec": usedCodec, "skipped": false,
              ]))
          }
        } else {
          try? FileManager.default.removeItem(at: outURL)
          finish(.failure(writer.error?.localizedDescription ?? "Writer failed"))
        }
      }
    }
  }

  // MARK: - Cancel

  func cancel(id: String?) {
    lock.lock()
    if id == nil || id == activeId {
      cancelled = true
    } else {
      // Either already finished, or it hasn't registered yet — remember it so
      // `compress` starts out cancelled. Dart issues one compress at a time, so
      // the latest id is enough (matches the Android engine).
      preCancelledId = id
    }
    lock.unlock()
  }

  /// Cancel whatever is running. Used on engine detach, where there is no id to
  /// target — the pumps observe `cancelled` and unwind on their own queues.
  func cancelAll() {
    cancel(id: nil)
  }

  private func isCancelled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  // MARK: - Helpers

  func clampDuration(_ full: Int64, _ config: CompressionConfig) -> Int64 {
    if let start = config.trimStartMs, let end = config.trimEndMs {
      return max(min(end, full) - start, 1)
    }
    return full
  }

  /// Release the finished job's reader/writer. Split out of `compress` so
  /// `finish` can call it through an optional `self`.
  private func clearActiveJob() {
    lock.lock()
    reader = nil
    writer = nil
    lock.unlock()
  }

}
